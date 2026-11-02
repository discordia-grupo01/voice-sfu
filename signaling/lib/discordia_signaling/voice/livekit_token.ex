defmodule DiscordiaSignaling.Voice.LiveKitToken do
  @moduledoc "Signs short-lived LiveKit access tokens for an authenticated user."

  alias DiscordiaSignaling.Voice.ScreenShare

  @screen_share_sources ["screen_share", "screen_share_audio"]

  @spec issue(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def issue(identity, name, room_name)
      when is_binary(identity) and identity != "" and is_binary(name) and name != "" and
             is_binary(room_name) and room_name != "" do
    issue(identity, name, room_name, true)
  end

  def issue(_identity, _name, _room_name), do: {:error, :invalid_input}

  @spec issue(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, atom()}
  def issue(identity, name, room_name, can_publish)
      when is_binary(identity) and identity != "" and is_binary(name) and name != "" and
             is_binary(room_name) and room_name != "" and is_boolean(can_publish) do
    sign(identity, name, %{
      "roomJoin" => true,
      "room" => room_name,
      "canPublish" => can_publish,
      "canSubscribe" => true,
      "canPublishData" => true
    })
  end

  def issue(_identity, _name, _room_name, _can_publish), do: {:error, :invalid_input}

  @spec issue_screen_share(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def issue_screen_share(user_id, name, room_name)
      when is_binary(user_id) and user_id != "" and is_binary(name) and name != "" and
             is_binary(room_name) and room_name != "" do
    sign(ScreenShare.identity(user_id), name, %{
      "roomJoin" => true,
      "room" => room_name,
      "canPublish" => true,
      "canPublishSources" => @screen_share_sources,
      "canSubscribe" => false,
      "canPublishData" => false
    })
  end

  def issue_screen_share(_user_id, _name, _room_name), do: {:error, :invalid_input}

  defp sign(identity, name, video_grant) do
    config = Application.get_env(:discordia_signaling, :livekit, [])
    api_key = Keyword.get(config, :api_key, "")
    api_secret = Keyword.get(config, :api_secret, "")
    ttl = Keyword.get(config, :token_ttl_seconds, 3600)

    if api_key == "" or api_secret == "" do
      {:error, :not_configured}
    else
      now = System.system_time(:second)

      claims = %{
        "iss" => api_key,
        "sub" => identity,
        "name" => name,
        "nbf" => now,
        "exp" => now + ttl,
        "video" => video_grant
      }

      jwk = JOSE.JWK.from_oct(api_secret)
      signed = JOSE.JWT.sign(jwk, %{"alg" => "HS256", "typ" => "JWT"}, claims)
      {_, token} = JOSE.JWS.compact(signed)
      {:ok, token}
    end
  end
end
