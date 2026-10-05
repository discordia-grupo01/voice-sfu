defmodule DiscordiaSignaling.TestHelpers do
  def put_livekit_config(
        config \\ [
          api_key: "test-key",
          api_secret: "test-secret",
          url: "ws://test-livekit:7880",
          token_ttl_seconds: 3600
        ]
      ) do
    previous = Application.get_env(:discordia_signaling, :livekit)
    Application.put_env(:discordia_signaling, :livekit, config)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:discordia_signaling, :livekit, previous)
      else
        Application.delete_env(:discordia_signaling, :livekit)
      end
    end)
  end

  def signed_access_token(claims \\ %{}) do
    default_claims = %{
      "sub" => "user-1",
      "exp" => System.system_time(:second) + 3600
    }

    jwt = JOSE.JWT.from_map(Map.merge(default_claims, claims))

    signed =
      JOSE.JWT.sign(JOSE.JWK.from_oct("jwt-secret"), %{"alg" => "HS256", "typ" => "JWT"}, jwt)

    {_, token} = JOSE.JWS.compact(signed)
    token
  end
end

defmodule DiscordiaSignaling.TestLiveKitRoomService do
  def remove_participant(_room_name, _identity) do
    Application.get_env(:discordia_signaling, :test_room_service_result, :ok)
  end
end
