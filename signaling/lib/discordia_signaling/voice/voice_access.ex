defmodule DiscordiaSignaling.Voice.VoiceAccess do
  @moduledoc """
  Authorization boundary for LiveKit room access.

  The development mode allows any authenticated user so the first LiveKit
  flow can be exercised locally. Production must replace this policy with the
  server/channel membership check owned by the servers domain.
  """

  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @spec authorize(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def authorize(user_id, channel_id, authorization_header \\ nil)

  def authorize(user_id, channel_id, authorization_header)
      when is_binary(user_id) and user_id != "" and is_binary(channel_id) and channel_id != "" do
    case authorize_with_permissions(user_id, channel_id, authorization_header) do
      {:ok, room_name, _name, _can_publish} -> {:ok, room_name}
      error -> error
    end
  end

  def authorize(_user_id, _channel_id, _authorization_header), do: {:error, :forbidden}

  @spec authorize_with_name(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()} | {:error, atom()}
  def authorize_with_name(user_id, channel_id, authorization_header \\ nil) do
    case authorize_with_permissions(user_id, channel_id, authorization_header) do
      {:ok, room_name, name, _can_publish} -> {:ok, room_name, name}
      error -> error
    end
  end

  @spec authorize_with_permissions(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t(), boolean()} | {:error, atom()}
  def authorize_with_permissions(user_id, channel_id, authorization_header \\ nil)

  def authorize_with_permissions(user_id, channel_id, authorization_header)
      when is_binary(user_id) and user_id != "" and is_binary(channel_id) and channel_id != "" do
    if Regex.match?(@uuid_pattern, channel_id) do
      case authz_mode() do
        "allow_authenticated" ->
          {:ok, room_name(channel_id), user_id, true}

        "servers_api" ->
          case authorize_with_servers(user_id, channel_id, authorization_header) do
            {:ok, room_name, name, can_publish, _server_id} ->
              {:ok, room_name, name, can_publish}

            error ->
              error
          end

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :forbidden}
    end
  end

  def authorize_with_permissions(_user_id, _channel_id, _authorization_header),
    do: {:error, :forbidden}

  defp authz_mode do
    System.get_env(
      "VOICE_AUTHZ_MODE",
      Application.get_env(:discordia_signaling, :servers, [])[:authz_mode] || "deny"
    )
  end

  defp room_name(channel_id), do: "voice:" <> channel_id

  defp authorize_with_servers(_user_id, _channel_id, authorization_header)
       when not is_binary(authorization_header) or authorization_header == "" do
    {:error, :forbidden}
  end

  defp authorize_with_servers(user_id, channel_id, authorization_header) do
    base_url = Application.get_env(:discordia_signaling, :servers, [])[:url]
    url = String.to_charlist(base_url <> "/v1/channels/" <> channel_id <> "/voice-access")
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    case :httpc.request(:get, {url, headers}, [connect_timeout: 2_000, timeout: 4_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"allowed" => true} = response} ->
            name = Map.get(response, "name", user_id)
            can_publish = Map.get(response, "muted") != true

            {:ok, room_name(channel_id),
             if(is_binary(name) and name != "", do: name, else: user_id), can_publish,
             Map.get(response, "server_id")}

          _ ->
            {:error, :forbidden}
        end

      {:ok, {{_, status, _}, _headers, _body}} when status in [401, 403, 404] ->
        {:error, :forbidden}

      _ ->
        {:error, :not_configured}
    end
  end

  @spec authorize_with_details(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def authorize_with_details(user_id, channel_id, authorization_header \\ nil)

  def authorize_with_details(user_id, _channel_id, _authorization_header)
      when not is_binary(user_id) or user_id == "",
      do: {:error, :forbidden}

  def authorize_with_details(user_id, channel_id, authorization_header) do
    with {:ok, room_name, name, can_publish, server_id} <-
           authorize_details(user_id, channel_id, authorization_header) do
      {:ok,
       %{
         room_name: room_name,
         name: name,
         can_publish: can_publish,
         server_id: server_id
       }}
    end
  end

  defp authorize_details(user_id, channel_id, authorization_header) do
    if Regex.match?(@uuid_pattern, channel_id) do
      case authz_mode() do
        "allow_authenticated" ->
          {:ok, room_name(channel_id), user_id, true, nil}

        "servers_api" ->
          authorize_with_servers(user_id, channel_id, authorization_header)

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :forbidden}
    end
  end
end
