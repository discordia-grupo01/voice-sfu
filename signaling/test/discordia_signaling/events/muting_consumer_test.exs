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

  test "stops the screen share of a muted member" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-7",
        "server_id" => "server-1",
        "user_id" => "mute-user-1",
        "until_at" => "2026-10-07T23:00:00Z"
      })

    assert :ack = MutingConsumer.process_payload("servers.member_muted", payload)
    assert_received {:removed_participant, "voice:mute-room", "mute-user-1:screen"}
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
    refute_received {:removed_participant, _, "mute-user-1:screen"}
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

  describe "channel access and deletion events" do
    setup do
      VoiceSessionRegistry.switch("access-user-1", "voice:access-channel")
      VoiceSessionRegistry.switch("access-user-2", "voice:access-channel")
      VoiceSessionRegistry.switch("access-user-3", "voice:other-channel")

      on_exit(fn ->
        Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
        VoiceSessionRegistry.leave("access-user-1", "voice:access-channel")
        VoiceSessionRegistry.leave("access-user-2", "voice:access-channel")
        VoiceSessionRegistry.leave("access-user-3", "voice:other-channel")
      end)

      :ok
    end

    test "removes revoked users from that channel's room" do
      payload = access_revoked_payload(["access-user-1"])

      assert :ack = MutingConsumer.process_payload("servers.channel_access_revoked", payload)
      assert VoiceSessionRegistry.active_room("access-user-1") == nil
      assert VoiceSessionRegistry.active_room("access-user-2") == "voice:access-channel"
    end

    test "ignores revoked users in another room or without a room" do
      payload = access_revoked_payload(["access-user-3", "not-in-voice"])

      assert :ack = MutingConsumer.process_payload("servers.channel_access_revoked", payload)
      assert VoiceSessionRegistry.active_room("access-user-3") == "voice:other-channel"
      assert VoiceSessionRegistry.active_room("not-in-voice") == nil
    end

    test "retries a revocation when LiveKit is unavailable" do
      Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})
      payload = access_revoked_payload(["access-user-1", "access-user-2"])

      assert :retry = MutingConsumer.process_payload("servers.channel_access_revoked", payload)
      assert VoiceSessionRegistry.active_room("access-user-1") == "voice:access-channel"

      Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

      assert :ack = MutingConsumer.process_payload("servers.channel_access_revoked", payload)
      assert :ack = MutingConsumer.process_payload("servers.channel_access_revoked", payload)
      assert VoiceSessionRegistry.active_room("access-user-1") == nil
      assert VoiceSessionRegistry.active_room("access-user-2") == nil
    end

    test "closes the room of a deleted channel" do
      payload =
        Jason.encode!(%{
          "event_id" => "event-8",
          "occurred_at" => "2026-10-08T12:00:00Z",
          "server_id" => "server-1",
          "channel_id" => "access-channel"
        })

      assert :ack = MutingConsumer.process_payload("servers.channel_deleted", payload)
      assert VoiceSessionRegistry.active_room("access-user-1") == nil
      assert VoiceSessionRegistry.active_room("access-user-2") == nil
      assert VoiceSessionRegistry.active_room("access-user-3") == "voice:other-channel"
    end

    test "closes every room of a deleted server" do
      payload = server_deleted_payload(["access-channel", "other-channel", "text-channel"])

      assert :ack = MutingConsumer.process_payload("servers.server_deleted", payload)
      assert VoiceSessionRegistry.active_room("access-user-1") == nil
      assert VoiceSessionRegistry.active_room("access-user-2") == nil
      assert VoiceSessionRegistry.active_room("access-user-3") == nil
    end

    test "retries a deletion when LiveKit is unavailable" do
      Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

      assert :retry =
               MutingConsumer.process_payload(
                 "servers.server_deleted",
                 server_deleted_payload(["access-channel"])
               )

      assert VoiceSessionRegistry.active_room("access-user-1") == "voice:access-channel"
    end

    test "acks invalid channel access and deletion events" do
      invalid = [
        {"servers.channel_access_revoked", access_revoked_payload([])},
        {"servers.channel_access_revoked", access_revoked_payload([""])},
        {"servers.channel_access_revoked", access_revoked_payload("access-user-1")},
        {"servers.channel_deleted", Jason.encode!(%{"event_id" => "event-9"})},
        {"servers.server_deleted", server_deleted_payload([1])},
        {"servers.server_deleted", "not-json"}
      ]

      for {routing_key, payload} <- invalid do
        assert :ack = MutingConsumer.process_payload(routing_key, payload)
      end

      assert VoiceSessionRegistry.active_room("access-user-1") == "voice:access-channel"
    end
  end

  defp access_revoked_payload(user_ids) do
    Jason.encode!(%{
      "event_id" => "event-7",
      "occurred_at" => "2026-10-08T12:00:00Z",
      "server_id" => "server-1",
      "channel_id" => "access-channel",
      "user_ids" => user_ids
    })
  end

  defp server_deleted_payload(channel_ids) do
    Jason.encode!(%{
      "event_id" => "event-10",
      "occurred_at" => "2026-10-08T12:00:00Z",
      "server_id" => "server-1",
      "channel_ids" => channel_ids
    })
  end
end
