defmodule DiscordiaSignaling.Events.PresenceConsumerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.PresenceConsumer
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  test "replicates valid presence events into the local registry" do
    user_id = "consumer-user"

    payload =
      Jason.encode!(%{
        "event_id" => "consumer-join",
        "occurred_at" => "2026-10-07T12:00:00Z",
        "server_id" => "server-1",
        "room_id" => "room-consumer",
        "participant_id" => user_id,
        "name" => "Ada"
      })

    assert :ack = PresenceConsumer.process_payload("voice.participant_joined", payload)
    assert VoiceSessionRegistry.active_room(user_id) == "voice:room-consumer"

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_left",
      "occurred_at" => "2026-10-07T12:01:00Z",
      "server_id" => "server-1",
      "room_id" => "room-consumer",
      "participant_id" => user_id,
      "name" => "Ada"
    })

    assert VoiceSessionRegistry.active_room(user_id) == nil
  end

  test "acks malformed or unsupported events without changing state" do
    assert :ack = PresenceConsumer.process_payload("voice.participant_joined", "not-json")
    assert :ack = PresenceConsumer.process_payload("voice.participant_joined", "[]")
    assert :ack = PresenceConsumer.process_payload("voice.unknown", "{}")
  end
end
