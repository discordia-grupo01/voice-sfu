defmodule DiscordiaSignaling.Voice.LiveKitRoomService do
  @moduledoc "Applies participant and room controls to LiveKit rooms."

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

  # LiveKit only lets roomAdmin act on the room named in the grant, and
  # DeleteRoom also needs roomCreate.
  defp request(config, path, body) do
    now = System.system_time(:second)

    claims = %{
      "iss" => config.api_key,
      "sub" => "discordia-signaling",
      "nbf" => now,
      "exp" => now + 60,
      "video" => %{"roomAdmin" => true, "roomCreate" => true, "room" => body["room"]}
    }

    jwk = JOSE.JWK.from_oct(config.api_secret)
    signed = JOSE.JWT.sign(jwk, %{"alg" => "HS256", "typ" => "JWT"}, claims)
    {_, token} = JOSE.JWS.compact(signed)
    body = Jason.encode!(body)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case :httpc.request(
           :post,
           {String.to_charlist(config.url <> path), headers, ~c"application/json", body},
           [{:timeout, 5_000}],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, _body}} -> :ok
      {:ok, {{_, 404, _}, _headers, _body}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp api_url(url) do
    url
    |> String.replace_prefix("ws://", "http://")
    |> String.replace_prefix("wss://", "https://")
    |> String.trim_trailing("/")
  end
end
