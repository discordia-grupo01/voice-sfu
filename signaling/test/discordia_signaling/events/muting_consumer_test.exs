defmodule DiscordiaSignaling.Events.MutingConsumerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.MutingConsumer
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  setup do
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
    VoiceSessionRegistry.switch("mute-user-1", "voice:mute-room")

    on_exit(fn ->
      VoiceSessionRegistry.leave("mute-user-1", "voice:mute-room")

      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end
    end)

    :ok
  end

  test "disables publishing without removing the active session" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-1",
        "server_id" => "server-1",
        "user_id" => "mute-user-1",
        "until_at" => "2026-10-07T23:00:00Z"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_muted", payload)
    assert_receive {:publish_permission, "voice:mute-room", "mute-user-1", false}
    assert VoiceSessionRegistry.active_room("mute-user-1") == "voice:mute-room"
  end

  test "restores publishing for an unmuted member" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-2",
        "server_id" => "server-1",
        "user_id" => "mute-user-1"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_unmuted", payload)
    assert_receive {:publish_permission, "voice:mute-room", "mute-user-1", true}
  end

  test "acks malformed and unsupported events" do
    assert :ack = MutingConsumer.process_payload("servers.member_muted", "not-json")
    assert :ack = MutingConsumer.process_payload("servers.member_deleted", "{}")
  end

  test "acks a muted event without the required expiration" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-3",
        "server_id" => "server-1",
        "user_id" => "mute-user-1"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_muted", payload)
    refute_received {:publish_permission, _, _, _}
  end

  test "acks events for users without an active voice session" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-4",
        "server_id" => "server-1",
        "user_id" => "not-in-voice",
        "until_at" => "2026-10-07T23:00:00Z"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_muted", payload)
    refute_received {:publish_permission, _, _, _}
  end

  test "acks when LiveKit no longer has the participant" do
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :not_found})

    payload =
      Jason.encode!(%{
        "event_id" => "event-5",
        "server_id" => "server-1",
        "user_id" => "mute-user-1",
        "until_at" => "2026-10-07T23:00:00Z"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_muted", payload)
    assert_received {:publish_permission, "voice:mute-room", "mute-user-1", false}
  end

  test "retries when LiveKit returns a transient error" do
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    payload =
      Jason.encode!(%{
        "event_id" => "event-6",
        "server_id" => "server-1",
        "user_id" => "mute-user-1",
        "until_at" => "2026-10-07T23:00:00Z"
      })

    assert :retry = MutingConsumer.process_payload("servers.member_muted", payload)
    assert_received {:publish_permission, "voice:mute-room", "mute-user-1", false}
  end
end
