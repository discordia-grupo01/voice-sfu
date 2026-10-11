defmodule DiscordiaSignaling.Voice.LiveKitTokenTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.LiveKitToken
  alias DiscordiaSignaling.TestHelpers

  setup do
    TestHelpers.put_livekit_config()
    :ok
  end

  test "issues a short-lived token with room-scoped grants" do
    assert {:ok, token} = LiveKitToken.issue("user-1", "Fabri", "room-1")

    assert {true, jwt, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_oct("test-secret"), ["HS256"], token)

    claims = jwt.fields
    assert claims["iss"] == "test-key"
    assert claims["sub"] == "user-1"
    assert claims["name"] == "Fabri"

    assert claims["video"] == %{
             "roomJoin" => true,
             "room" => "room-1",
             "canPublish" => true,
             "canSubscribe" => true,
             "canPublishData" => true
           }

    assert claims["exp"] > claims["nbf"]
  end

  test "issues a muted token that keeps room access and subscriptions" do
    assert {:ok, token} = LiveKitToken.issue("user-1", "Fabri", "room-1", false)

    assert {true, jwt, _jws} =
             JOSE.JWT.verify_strict(JOSE.JWK.from_oct("test-secret"), ["HS256"], token)

    assert jwt.fields["video"] == %{
             "roomJoin" => true,
             "room" => "room-1",
             "canPublish" => false,
             "canSubscribe" => true,
             "canPublishData" => true
           }
  end

  test "rejects blank identity or room" do
    assert {:error, :invalid_input} = LiveKitToken.issue("", "Fabri", "room-1")
    assert {:error, :invalid_input} = LiveKitToken.issue("user-1", "", "room-1")
    assert {:error, :invalid_input} = LiveKitToken.issue("user-1", "Fabri", "")
    assert {:error, :invalid_input} = LiveKitToken.issue(nil, "Fabri", "room-1")
    assert {:error, :invalid_input} = LiveKitToken.issue("user-1", "Fabri", "room-1", nil)
  end

  test "reports missing LiveKit configuration" do
    TestHelpers.put_livekit_config(api_key: "", api_secret: "")

    assert {:error, :not_configured} = LiveKitToken.issue("user-1", "Fabri", "room-1")
  end
end
