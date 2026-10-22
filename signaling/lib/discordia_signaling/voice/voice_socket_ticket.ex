defmodule DiscordiaSignaling.Voice.VoiceSocketTicket do
  @moduledoc "Issues short-lived credentials for the browser voice presence socket."

  @ttl_seconds 30
  @purpose "voice_presence_socket"

  @spec issue(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def issue(user_id) when is_binary(user_id) and user_id != "" do
    secret = System.get_env("JWT_SECRET", "")

    if secret == "" do
      {:error, :not_configured}
    else
      now = System.system_time(:second)

      claims = %{
        "sub" => user_id,
        "typ" => @purpose,
        "iat" => now,
        "exp" => now + @ttl_seconds,
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      signed = JOSE.JWT.sign(JOSE.JWK.from_oct(secret), %{"alg" => "HS256"}, claims)
      {_, token} = JOSE.JWS.compact(signed)
      {:ok, token}
    end
  end

  def issue(_user_id), do: {:error, :invalid_input}

  @spec verify(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def verify(token) when is_binary(token) and token != "" do
    secret = System.get_env("JWT_SECRET", "")

    if secret == "" do
      {:error, :not_configured}
    else
      try do
        case JOSE.JWT.verify_strict(JOSE.JWK.from_oct(secret), ["HS256"], token) do
          {true, jwt, _jws} -> validate_claims(Map.get(jwt, :fields, %{}))
          _ -> {:error, :invalid_ticket}
        end
      rescue
        _ -> {:error, :invalid_ticket}
      end
    end
  end

  def verify(_token), do: {:error, :invalid_ticket}

  def ttl_seconds, do: @ttl_seconds

  defp validate_claims(%{"sub" => user_id, "typ" => @purpose, "exp" => exp})
       when is_binary(user_id) and user_id != "" and is_integer(exp) do
    if exp > System.system_time(:second), do: {:ok, user_id}, else: {:error, :expired}
  end

  defp validate_claims(_claims), do: {:error, :invalid_ticket}
end
