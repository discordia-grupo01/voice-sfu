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

  test "replicates private call events through the private call coordinator" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:presence-recipient")

    payload =
      Jason.encode!(%{
        "event_id" => "private-call-event",
        "call_id" => "presence-call",
        "conversation_id" => "conversation-1",
        "caller_id" => "presence-caller",
        "recipient_id" => "presence-recipient",
        "room_name" => "private-call:presence-call",
        "status" => "ringing"
      })

    assert :ack = PresenceConsumer.process_payload("voice.private_call", payload)
    assert_receive {:private_call, "private_call_incoming", %{"call_id" => "presence-call"}}
  end

  test "ignores broker consume confirmations" do
    state = %{
      connection: nil,
      channel: nil,
      queue: nil,
      exchange: "discordia.events",
      url: "amqp://test"
    }

    assert {:noreply, ^state} = PresenceConsumer.handle_info({:basic_consume_ok, %{}}, state)
  end
end
