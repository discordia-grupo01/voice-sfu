defmodule DiscordiaSignaling.Voice.LiveKitToken do
  @moduledoc "Signs short-lived LiveKit access tokens for an authenticated user."

  @spec issue(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def issue(identity, name, room_name)
      when is_binary(identity) and identity != "" and is_binary(name) and name != "" and
             is_binary(room_name) and room_name != "" do
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
        "video" => %{
          "roomJoin" => true,
          "room" => room_name,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        }
      }

      jwk = JOSE.JWK.from_oct(api_secret)
      signed = JOSE.JWT.sign(jwk, %{"alg" => "HS256", "typ" => "JWT"}, claims)
      {_, token} = JOSE.JWS.compact(signed)
      {:ok, token}
    end
  end

  def issue(_identity, _name, _room_name), do: {:error, :invalid_input}
end
