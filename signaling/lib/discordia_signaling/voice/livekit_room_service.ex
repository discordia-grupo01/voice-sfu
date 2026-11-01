defmodule DiscordiaSignaling.Voice.LiveKitRoomService do
  @moduledoc "Applies participant and room controls to LiveKit rooms."

  @receive_timeout 4_000

  @spec active_participants() :: {:ok, [map()]} | {:error, atom()}
  def active_participants do
    with {:ok, config} <- livekit_config(),
         {:ok, rooms} <- request_json(config, "/twirp/livekit.RoomService/ListRooms", %{}),
         {:ok, participants} <- list_room_participants(config, rooms) do
      {:ok, participants}
    end
  end

  @spec set_publish_permission(String.t(), String.t(), boolean()) :: :ok | {:error, atom()}
  def set_publish_permission(room_name, identity, can_publish)
      when is_binary(room_name) and room_name != "" and is_binary(identity) and identity != "" and
             is_boolean(can_publish) do
    with {:ok, config} <- livekit_config() do
      body = %{
        "room" => room_name,
        "identity" => identity,
        "permission" => %{"canPublish" => can_publish}
      }

      request(config, "/twirp/livekit.RoomService/UpdateParticipant", body)
    end
  end

  def set_publish_permission(_room_name, _identity, _can_publish),
    do: {:error, :invalid_input}

  @spec remove_participant(String.t(), String.t()) :: :ok | {:error, atom()}
  def remove_participant(room_name, identity)
      when is_binary(room_name) and room_name != "" and is_binary(identity) and identity != "" do
    with {:ok, config} <- livekit_config() do
      body = %{"room" => room_name, "identity" => identity}
      request(config, "/twirp/livekit.RoomService/RemoveParticipant", body)
    end
  end

  def remove_participant(_room_name, _identity), do: {:error, :invalid_input}

  @spec delete_room(String.t()) :: :ok | {:error, atom()}
  def delete_room(room_name) when is_binary(room_name) and room_name != "" do
    with {:ok, config} <- livekit_config() do
      request(config, "/twirp/livekit.RoomService/DeleteRoom", %{"room" => room_name})
    end
  end

  def delete_room(_room_name), do: {:error, :invalid_input}

  defp livekit_config do
    config = Application.get_env(:discordia_signaling, :livekit, [])
    api_key = Keyword.get(config, :api_key, "")
    api_secret = Keyword.get(config, :api_secret, "")

    if api_key == "" or api_secret == "" do
      {:error, :not_configured}
    else
      {:ok,
       %{
         url: api_url(Keyword.get(config, :url, "ws://localhost:7880")),
         api_key: api_key,
         api_secret: api_secret
       }}
    end
  end

  # ListRooms uses the account-level roomList grant. Room-scoped operations
  # use roomAdmin, and DeleteRoom also needs roomCreate.
  defp request(config, path, body), do: request(config, path, body, false)

  defp request_json(config, path, body), do: request(config, path, body, true)

  defp request(config, path, body, decode_response?) do
    now = System.system_time(:second)

    claims = %{
      "iss" => config.api_key,
      "sub" => "discordia-signaling",
      "nbf" => now,
      "exp" => now + 60,
      "video" => video_grant(path, body)
    }

    jwk = JOSE.JWK.from_oct(config.api_secret)
    signed = JOSE.JWT.sign(jwk, %{"alg" => "HS256", "typ" => "JWT"}, claims)
    {_, token} = JOSE.JWS.compact(signed)
    body = Jason.encode!(body)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case :httpc.request(
           :post,
           {String.to_charlist(config.url <> path), headers, ~c"application/json", body},
           [{:timeout, @receive_timeout}],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, response_body}} when decode_response? ->
        Jason.decode(response_body)

      {:ok, {{_, 200, _}, _headers, _body}} ->
        :ok

      {:ok, {{_, 404, _}, _headers, _body}} ->
        {:error, :not_found}

      {:ok, {{_, 400, _}, _headers, _body}} ->
        {:error, :bad_request}

      {:ok, {{_, 401, _}, _headers, _body}} ->
        {:error, :unauthorized}

      {:ok, {{_, 403, _}, _headers, _body}} ->
        {:error, :forbidden}

      {:ok, {{_, 500, _}, _headers, _body}} ->
        {:error, :internal_server_error}

      _ ->
        {:error, :unavailable}
    end
  end

  defp video_grant("/twirp/livekit.RoomService/ListRooms", _body),
    do: %{"roomList" => true}

  defp video_grant("/twirp/livekit.RoomService/DeleteRoom", body),
    do: %{"roomAdmin" => true, "roomCreate" => true, "room" => body["room"]}

  defp video_grant(_path, body),
    do: %{"roomAdmin" => true, "room" => body["room"]}

  defp list_room_participants(config, %{"rooms" => rooms}) when is_list(rooms) do
    rooms
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => room_name} = room, {:ok, participants} ->
        case request_json(
               config,
               "/twirp/livekit.RoomService/ListParticipants",
               %{"room" => room_name}
             ) do
          {:ok, %{"participants" => room_participants}} when is_list(room_participants) ->
            room_participants =
              normalize_participants(room_name, room_started_at(room), room_participants)

            {:cont, {:ok, participants ++ room_participants}}

          {:ok, _response} ->
            {:halt, {:error, :invalid_response}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _room, _acc ->
        {:halt, {:error, :invalid_response}}
    end)
  end

  defp list_room_participants(_config, _response), do: {:error, :invalid_response}

  defp room_started_at(room) do
    cond do
      millis = positive_integer(room["creation_time_ms"] || room["creationTimeMs"]) ->
        millis |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

      seconds = positive_integer(room["creation_time"] || room["creationTime"]) ->
        seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()

      true ->
        nil
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp normalize_participants(room_name, room_started_at, participants) do
    Enum.flat_map(participants, fn
      %{"identity" => identity, "name" => name} when is_binary(identity) and identity != "" ->
        [
          %{
            room_name: room_name,
            room_started_at: room_started_at,
            identity: identity,
            name: if(is_binary(name) and name != "", do: name, else: identity),
            server_id: nil,
            occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]

      _participant ->
        []
    end)
  end

  defp api_url(url) do
    url
    |> String.replace_prefix("ws://", "http://")
    |> String.replace_prefix("wss://", "https://")
    |> String.trim_trailing("/")
  end
end
