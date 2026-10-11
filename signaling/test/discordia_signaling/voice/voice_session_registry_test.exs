defmodule DiscordiaSignaling.Voice.VoiceSessionRegistryTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  setup do
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
    previous_publisher = Application.get_env(:discordia_signaling, :voice_presence_publisher)

    Application.put_env(
      :discordia_signaling,
      :voice_presence_publisher,
      DiscordiaSignaling.TestVoicePresencePublisher
    )

    Application.put_env(:discordia_signaling, :test_presence_recipient, self())
    VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    VoiceSessionRegistry.leave("registry-user-1", "voice:room-2")

    on_exit(fn ->
      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end

      if previous_publisher do
        Application.put_env(:discordia_signaling, :voice_presence_publisher, previous_publisher)
      else
        Application.delete_env(:discordia_signaling, :voice_presence_publisher)
      end

      Application.delete_env(:discordia_signaling, :test_presence_recipient)
    end)

    :ok
  end

  test "replaces the previous room for an identity" do
    assert {:ok, nil} = VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")

    assert {:ok, "voice:room-1"} =
             VoiceSessionRegistry.switch("registry-user-1", "voice:room-2")

    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-2"
  end

  test "publishes a snapshot-compatible event when a participant joins and leaves" do
    assert {:ok, nil} =
             VoiceSessionRegistry.switch(
               "presence-user",
               "voice:room-1",
               "Ada",
               "server-1"
             )

    assert_receive {:voice_presence_published, %{"event_type" => "voice.participant_joined"}}

    assert [%{"participant_id" => "presence-user", "name" => "Ada", "room_id" => "room-1"}] =
             VoiceSessionRegistry.participants("server-1")

    assert :ok = VoiceSessionRegistry.leave("presence-user", "voice:room-1")
    assert_receive {:voice_presence_published, %{"event_type" => "voice.participant_left"}}
    assert VoiceSessionRegistry.participants("server-1") == []
  end

  test "replicates newer presence events and ignores stale events" do
    user_id = "replicated-user"

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_joined",
      "event_id" => "remote-join",
      "occurred_at" => "2026-10-07T12:00:00Z",
      "server_id" => "server-1",
      "room_id" => "room-1",
      "participant_id" => user_id,
      "name" => "Ada"
    })

    assert [%{"participant_id" => ^user_id, "room_id" => "room-1"}] =
             VoiceSessionRegistry.participants("server-1")

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_left",
      "event_id" => "stale-leave",
      "occurred_at" => "2026-10-07T11:00:00Z",
      "server_id" => "server-1",
      "room_id" => "room-1",
      "participant_id" => user_id,
      "name" => "Ada"
    })

    assert VoiceSessionRegistry.active_room(user_id) == "voice:room-1"
  end

  test "replicated leave removes the matching current room" do
    user_id = "replicated-leave-user"

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_joined",
      "event_id" => "remote-join-2",
      "occurred_at" => "2026-10-07T12:00:00Z",
      "server_id" => "server-1",
      "room_id" => "room-2",
      "participant_id" => user_id,
      "name" => "Ada"
    })

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_left",
      "event_id" => "remote-leave-2",
      "occurred_at" => "2026-10-07T12:01:00Z",
      "server_id" => "server-1",
      "room_id" => "room-2",
      "participant_id" => user_id,
      "name" => "Ada"
    })

    assert VoiceSessionRegistry.active_room(user_id) == nil
  end

  test "does not remove a newer room when an older room leaves" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-2")

    assert :ok = VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-2"
  end

  test "is idempotent when leaving an absent room" do
    assert :ok = VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    assert :ok = VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == nil
  end

  test "leaving the active room removes it from the registry" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")

    assert :ok = VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == nil
  end

  test "does not disconnect when requesting the same room" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    assert {:ok, "voice:room-1"} =
             VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
  end

  test "keeps the previous room when switching cannot disconnect it" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    assert {:error, :unavailable} =
             VoiceSessionRegistry.switch("registry-user-1", "voice:room-2")

    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-1"
  end

  test "treats an already absent LiveKit participant as a successful switch" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :not_found})

    assert {:ok, "voice:room-1"} =
             VoiceSessionRegistry.switch("registry-user-1", "voice:room-2")

    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-2"
  end

  test "keeps the active room when leaving fails" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    assert {:error, :unavailable} =
             VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")

    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-1"
  end

  test "closing a room removes every identity in it and keeps other rooms" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    VoiceSessionRegistry.switch("registry-user-2", "voice:room-1")
    VoiceSessionRegistry.switch("registry-user-3", "voice:room-2")

    assert :ok = VoiceSessionRegistry.close_room("voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == nil
    assert VoiceSessionRegistry.active_room("registry-user-2") == nil
    assert VoiceSessionRegistry.active_room("registry-user-3") == "voice:room-2"

    VoiceSessionRegistry.leave("registry-user-3", "voice:room-2")
  end

  test "treats an already deleted LiveKit room as closed" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :not_found})

    assert :ok = VoiceSessionRegistry.close_room("voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == nil
  end

  test "keeps the room sessions when closing fails" do
    VoiceSessionRegistry.switch("registry-user-1", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    assert {:error, :unavailable} = VoiceSessionRegistry.close_room("voice:room-1")
    assert VoiceSessionRegistry.active_room("registry-user-1") == "voice:room-1"

    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
    VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
  end
end
