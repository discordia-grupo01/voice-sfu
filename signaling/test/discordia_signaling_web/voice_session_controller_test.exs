defmodule DiscordiaSignalingWeb.VoiceSessionControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoiceSessionController

  @channel_id "750e8400-e29b-41d4-a716-446655440000"

  setup do
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    VoiceSessionRegistry.leave("session-controller-user", "voice:" <> @channel_id)
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    on_exit(fn ->
      if previous_mode do
        System.put_env("VOICE_AUTHZ_MODE", previous_mode)
      else
        System.delete_env("VOICE_AUTHZ_MODE")
      end
    end)

    :ok
  end

  test "leaves an active voice session" do
    user_id = "session-controller-user"
    VoiceSessionRegistry.switch(user_id, "voice:" <> @channel_id)
    conn = authenticated_conn(user_id)

    response = VoiceSessionController.delete(conn, %{"channel_id" => @channel_id})

    assert response.status == 204
    assert VoiceSessionRegistry.active_room(user_id) == nil
  end

  test "is idempotent when the user has no active session" do
    response =
      VoiceSessionController.delete(authenticated_conn("session-controller-user"), %{
        "channel_id" => @channel_id
      })

    assert response.status == 204
  end

  test "leaves an active session without reauthorizing the channel" do
    user_id = "session-controller-user"
    room_name = "voice:" <> @channel_id
    VoiceSessionRegistry.switch(user_id, room_name)
    System.put_env("VOICE_AUTHZ_MODE", "deny")

    response =
      VoiceSessionController.delete(authenticated_conn(user_id), %{"channel_id" => @channel_id})

    assert response.status == 204
    assert VoiceSessionRegistry.active_room(user_id) == nil
  end

  test "returns bad request when channel_id is missing" do
    response = VoiceSessionController.delete(authenticated_conn("session-controller-user"), %{})

    assert response.status == 400
    assert Jason.decode!(response.resp_body) == %{"error" => "channel_id_required"}
  end

  test "returns forbidden for an invalid identity" do
    conn = Plug.Conn.assign(conn(:delete, "/api/voice/session"), :current_user_id, nil)
    response = VoiceSessionController.delete(conn, %{"channel_id" => @channel_id})

    assert response.status == 403
    assert Jason.decode!(response.resp_body) == %{"error" => "voice_forbidden"}
  end

  test "keeps the session when LiveKit cannot disconnect the participant" do
    user_id = "session-controller-user"
    room_name = "voice:" <> @channel_id
    VoiceSessionRegistry.switch(user_id, room_name)
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    response =
      VoiceSessionController.delete(authenticated_conn(user_id), %{"channel_id" => @channel_id})

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "voice_unavailable"}
    assert VoiceSessionRegistry.active_room(user_id) == room_name
  end

  defp authenticated_conn(user_id) do
    Plug.Conn.assign(conn(:delete, "/api/voice/session"), :current_user_id, user_id)
  end
end
