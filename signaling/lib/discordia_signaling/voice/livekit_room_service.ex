defmodule DiscordiaSignaling.Voice.LiveKitRoomService do
  @moduledoc "Removes authenticated participants from LiveKit rooms."

  @spec remove_participant(String.t(), String.t()) :: :ok | {:error, atom()}
  def remove_participant(room_name, identity)
      when is_binary(room_name) and room_name != "" and is_binary(identity) and identity != "" do
    config = Application.get_env(:discordia_signaling, :livekit, [])
    api_key = Keyword.get(config, :api_key, "")
    api_secret = Keyword.get(config, :api_secret, "")

    if api_key == "" or api_secret == "" do
      {:error, :not_configured}
    else
      request(
        api_url(Keyword.get(config, :url, "ws://localhost:7880")),
        api_key,
        api_secret,
        room_name,
        identity
      )
    end
  end

  def remove_participant(_room_name, _identity), do: {:error, :invalid_input}

  defp request(url, api_key, api_secret, room_name, identity) do
    now = System.system_time(:second)

    claims = %{
      "iss" => api_key,
      "sub" => "discordia-signaling",
      "nbf" => now,
      "exp" => now + 60,
      "video" => %{"roomAdmin" => true}
    }

    jwk = JOSE.JWK.from_oct(api_secret)
    signed = JOSE.JWT.sign(jwk, %{"alg" => "HS256", "typ" => "JWT"}, claims)
    {_, token} = JOSE.JWS.compact(signed)
    body = Jason.encode!(%{"room" => room_name, "identity" => identity})
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
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
    |> Kernel.<>("/twirp/livekit.RoomService/RemoveParticipant")
  end
end
