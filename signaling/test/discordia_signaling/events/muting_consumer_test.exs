defmodule DiscordiaSignaling.Events.MutingConsumerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.MutingConsumer
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  setup do
    VoiceSessionRegistry.switch("mute-user-1", "voice:mute-room")

    on_exit(fn ->
      VoiceSessionRegistry.leave("mute-user-1", "voice:mute-room")
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
end
