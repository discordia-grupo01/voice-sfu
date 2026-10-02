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
    if Regex.match?(@uuid_pattern, channel_id) do
      case authz_mode() do
        "allow_authenticated" -> {:ok, room_name(channel_id)}
        "servers_api" -> authorize_with_servers(user_id, channel_id, authorization_header)
        _ -> {:error, :not_configured}
      end
    else
      {:error, :forbidden}
    end
  end

  def authorize(_user_id, _channel_id, _authorization_header), do: {:error, :forbidden}

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

  defp authorize_with_servers(_user_id, channel_id, authorization_header) do
    base_url = Application.get_env(:discordia_signaling, :servers, [])[:url]
    url = String.to_charlist(base_url <> "/v1/channels/" <> channel_id <> "/voice-access")
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"allowed" => true}} -> {:ok, room_name(channel_id)}
          _ -> {:error, :forbidden}
        end

      {:ok, {{_, status, _}, _headers, _body}} when status in [401, 403, 404] ->
        {:error, :forbidden}

      _ ->
        {:error, :not_configured}
    end
  end
end
