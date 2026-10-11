defmodule DiscordiaSignalingWeb.VoiceTokenControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoiceTokenController

  setup do
    TestHelpers.put_livekit_config()
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
    VoiceSessionRegistry.leave("user-1", "voice:550e8400-e29b-41d4-a716-446655440000")
    VoiceSessionRegistry.leave("user-1", "voice:650e8400-e29b-41d4-a716-446655440000")

    on_exit(fn ->
      if previous_mode,
        do: System.put_env("VOICE_AUTHZ_MODE", previous_mode),
        else: System.delete_env("VOICE_AUTHZ_MODE")

      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end
    end)

    :ok
  end

  test "returns a LiveKit token for the authenticated user" do
    conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, "user-1")

    conn =
      VoiceTokenController.create(conn, %{"channel_id" => "550e8400-e29b-41d4-a716-446655440000"})

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["identity"] == "user-1"
    assert body["name"] == "user-1"
    assert body["room_name"] == "voice:550e8400-e29b-41d4-a716-446655440000"
    assert body["url"] == "ws://test-livekit:7880"
    assert is_binary(body["token"])
  end

  test "replaces the active room when the user requests another channel" do
    first_channel = "550e8400-e29b-41d4-a716-446655440000"
    second_channel = "650e8400-e29b-41d4-a716-446655440000"
    first_conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, "user-1")
    second_conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, "user-1")

    assert VoiceTokenController.create(first_conn, %{"channel_id" => first_channel}).status == 200

    assert VoiceTokenController.create(second_conn, %{"channel_id" => second_channel}).status ==
             200

    assert VoiceSessionRegistry.active_room("user-1") == "voice:" <> second_channel
  end

  test "returns forbidden when the authenticated identity is invalid" do
    conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, nil)

    conn =
      VoiceTokenController.create(conn, %{"channel_id" => "550e8400-e29b-41d4-a716-446655440000"})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "voice_forbidden"}
  end

  test "returns service unavailable when LiveKit is not configured" do
    TestHelpers.put_livekit_config(api_key: "", api_secret: "")
    conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, "user-1")

    conn =
      VoiceTokenController.create(conn, %{"channel_id" => "550e8400-e29b-41d4-a716-446655440000"})

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"error" => "voice_not_configured"}
  end

  test "rejects a request without a channel id" do
    conn = Plug.Conn.assign(conn(:post, "/api/voice/token"), :current_user_id, "user-1")
    conn = VoiceTokenController.create(conn, %{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "channel_id_required"}
  end
end
