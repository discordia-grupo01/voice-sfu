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

    VoiceSessionRegistry.reconcile_snapshot([])
    VoiceSessionRegistry.participants()
    VoiceSessionRegistry.leave("registry-user-1", "voice:room-1")
    VoiceSessionRegistry.leave("registry-user-1", "voice:room-2")
    Application.put_env(:discordia_signaling, :test_presence_recipient, self())

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

  test "removes the screen share companion when the owner leaves" do
    assert {:ok, nil} = VoiceSessionRegistry.switch("screen-owner", "voice:room-1")

    assert :ok = VoiceSessionRegistry.leave("screen-owner", "voice:room-1")
    assert_received {:removed_participant, "voice:room-1", "screen-owner"}
    assert_received {:removed_participant, "voice:room-1", "screen-owner:screen"}
  end

  test "removes the screen share companion from the previous room on switch" do
    assert {:ok, nil} = VoiceSessionRegistry.switch("screen-switcher", "voice:room-1")

    assert {:ok, "voice:room-1"} =
             VoiceSessionRegistry.switch("screen-switcher", "voice:room-2")

    assert_received {:removed_participant, "voice:room-1", "screen-switcher:screen"}

    VoiceSessionRegistry.leave("screen-switcher", "voice:room-2")
  end

  test "keeps the session when LiveKit cannot remove it" do
    assert {:ok, nil} = VoiceSessionRegistry.switch("screen-retry", "voice:room-1")
    Application.put_env(:discordia_signaling, :test_room_service_result, {:error, :unavailable})

    assert {:error, :unavailable} =
             VoiceSessionRegistry.leave("screen-retry", "voice:room-1")

    assert VoiceSessionRegistry.active_room("screen-retry") == "voice:room-1"

    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)
    assert :ok = VoiceSessionRegistry.leave("screen-retry", "voice:room-1")
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

  test "stamps the leave after the join so other instances apply it" do
    assert {:ok, nil} =
             VoiceSessionRegistry.switch("stamp-user", "voice:room-1", "Ada", "server-1")

    assert_receive {:voice_presence_published,
                    %{"event_type" => "voice.participant_joined"} = joined}

    assert :ok = VoiceSessionRegistry.leave("stamp-user", "voice:room-1")

    assert_receive {:voice_presence_published, %{"event_type" => "voice.participant_left"} = left}

    assert DateTime.compare(
             DateTime.from_iso8601(left["occurred_at"]) |> elem(1),
             DateTime.from_iso8601(joined["occurred_at"]) |> elem(1)
           ) == :gt

    # What another instance does with the two events it receives.
    VoiceSessionRegistry.replicate_presence(joined)
    assert VoiceSessionRegistry.active_room("stamp-user") == "voice:room-1"

    VoiceSessionRegistry.replicate_presence(left)
    assert VoiceSessionRegistry.active_room("stamp-user") == nil
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

  test "broadcasts replicated presence to local socket subscribers" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_server:server-1")

    event = %{
      "event_type" => "voice.participant_joined",
      "event_id" => "remote-join-pubsub",
      "occurred_at" => "2026-10-07T12:00:00Z",
      "server_id" => "server-1",
      "room_id" => "room-1",
      "participant_id" => "replicated-pubsub-user",
      "name" => "Ada"
    }

    pushed = Map.put(event, "room_started_at", "2026-10-07T12:00:00Z")

    assert :ok = VoiceSessionRegistry.replicate_presence(event)
    assert_receive {:voice_presence, ^pushed}

    assert :ok = VoiceSessionRegistry.replicate_presence(event)
    refute_receive {:voice_presence, _event}
  end

  describe "call start" do
    test "the first participant in an empty room starts the call" do
      assert {:ok, nil} =
               VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")

      assert_receive {:voice_presence_published, %{"occurred_at" => joined_at}}

      started_at = VoiceSessionRegistry.room_started_at("room-1")
      assert started_at == millisecond_iso(joined_at)
      assert VoiceSessionRegistry.room_starts() == %{"room-1" => started_at}
    end

    test "later participants do not move the start" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      started_at = VoiceSessionRegistry.room_started_at("room-1")

      Process.sleep(5)
      VoiceSessionRegistry.switch("start-user-2", "voice:room-1", "Bea", "server-1")

      assert VoiceSessionRegistry.room_started_at("room-1") == started_at
    end

    test "the call goes on when the first participant leaves" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      VoiceSessionRegistry.switch("start-user-2", "voice:room-1", "Bea", "server-1")
      started_at = VoiceSessionRegistry.room_started_at("room-1")

      assert :ok = VoiceSessionRegistry.leave("start-user-1", "voice:room-1")

      assert VoiceSessionRegistry.room_started_at("room-1") == started_at
    end

    test "the call ends when the room empties and the next one starts again" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      first_start = VoiceSessionRegistry.room_started_at("room-1")

      assert :ok = VoiceSessionRegistry.leave("start-user-1", "voice:room-1")
      assert VoiceSessionRegistry.room_started_at("room-1") == nil
      assert VoiceSessionRegistry.room_starts() == %{}

      Process.sleep(5)
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")

      second_start = VoiceSessionRegistry.room_started_at("room-1")
      assert is_binary(second_start)
      assert second_start != first_start
    end

    test "switching rooms ends the call left empty and starts the new one" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      VoiceSessionRegistry.switch("start-user-1", "voice:room-2", "Ada", "server-1")

      assert VoiceSessionRegistry.room_started_at("room-1") == nil
      assert is_binary(VoiceSessionRegistry.room_started_at("room-2"))
    end

    test "closing a room ends its call" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      VoiceSessionRegistry.switch("start-user-2", "voice:room-1", "Bea", "server-1")

      assert :ok = VoiceSessionRegistry.close_room("voice:room-1")

      assert VoiceSessionRegistry.room_started_at("room-1") == nil
    end

    test "replicated events use their own timestamp, so every node agrees" do
      join = fn identity, at ->
        VoiceSessionRegistry.replicate_presence(%{
          "event_type" => "voice.participant_joined",
          "event_id" => "join-#{identity}",
          "occurred_at" => at,
          "server_id" => "server-1",
          "room_id" => "room-1",
          "participant_id" => identity,
          "name" => identity
        })
      end

      join.("remote-start-1", "2026-10-07T12:00:00.123456Z")
      join.("remote-start-2", "2026-10-07T12:05:00Z")
      assert VoiceSessionRegistry.room_started_at("room-1") == "2026-10-07T12:00:00.123Z"

      VoiceSessionRegistry.replicate_presence(%{
        "event_type" => "voice.participant_left",
        "event_id" => "leave-remote-start-1",
        "occurred_at" => "2026-10-07T12:10:00Z",
        "server_id" => "server-1",
        "room_id" => "room-1",
        "participant_id" => "remote-start-1",
        "name" => "remote-start-1"
      })

      assert VoiceSessionRegistry.room_started_at("room-1") == "2026-10-07T12:00:00.123Z"
    end

    test "socket subscribers get the start; the RabbitMQ event stays unchanged" do
      Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_server:server-1")

      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      started_at = VoiceSessionRegistry.room_started_at("room-1")

      assert_receive {:voice_presence,
                      %{
                        "event_type" => "voice.participant_joined",
                        "room_started_at" => ^started_at
                      }}

      assert_receive {:voice_presence_published, published}
      refute Map.has_key?(published, "room_started_at")

      VoiceSessionRegistry.leave("start-user-1", "voice:room-1")

      assert_receive {:voice_presence,
                      %{"event_type" => "voice.participant_left", "room_started_at" => nil}}
    end

    test "a reconciled room takes the LiveKit creation time" do
      VoiceSessionRegistry.reconcile_snapshot([
        %{
          identity: "reconciled-start-user",
          room_name: "voice:room-1",
          room_started_at: "2026-11-01T16:00:00Z",
          name: "Ada",
          server_id: nil
        }
      ])

      assert VoiceSessionRegistry.room_started_at("room-1") == "2026-11-01T16:00:00Z"
    end

    test "reconciling keeps a start already known and drops empty rooms" do
      VoiceSessionRegistry.switch("start-user-1", "voice:room-1", "Ada", "server-1")
      VoiceSessionRegistry.switch("start-user-2", "voice:room-2", "Bea", "server-1")
      started_at = VoiceSessionRegistry.room_started_at("room-1")

      VoiceSessionRegistry.reconcile_snapshot([
        %{
          identity: "start-user-1",
          room_name: "voice:room-1",
          room_started_at: "2020-01-01T00:00:00Z",
          name: "Ada",
          server_id: "server-1"
        }
      ])

      assert VoiceSessionRegistry.room_started_at("room-1") == started_at
      assert VoiceSessionRegistry.room_started_at("room-2") == nil
    end
  end

  describe "reconciliation right after joining" do
    setup do
      Application.put_env(:discordia_signaling, :reconcile_grace_ms, 60_000)
      on_exit(fn -> Application.put_env(:discordia_signaling, :reconcile_grace_ms, 0) end)
      :ok
    end

    test "keeps someone who is not in LiveKit yet" do
      VoiceSessionRegistry.switch("grace-user-1", "voice:room-1", "Ada", "server-1")

      VoiceSessionRegistry.reconcile_snapshot([])

      assert [%{"participant_id" => "grace-user-1", "room_id" => "room-1"}] =
               VoiceSessionRegistry.participants("server-1")

      assert is_binary(VoiceSessionRegistry.room_started_at("room-1"))
    end

    test "does not move someone back to the room LiveKit still lists" do
      VoiceSessionRegistry.switch("grace-user-1", "voice:room-2", "Ada", "server-1")

      VoiceSessionRegistry.reconcile_snapshot([
        %{identity: "grace-user-1", room_name: "voice:room-1", name: "Ada", server_id: nil}
      ])

      assert VoiceSessionRegistry.active_room("grace-user-1") == "voice:room-2"
      assert VoiceSessionRegistry.room_started_at("room-1") == nil
    end
  end

  describe "server of a reconciled participant" do
    test "comes back from the room after the participant was dropped" do
      VoiceSessionRegistry.switch("server-user-1", "voice:room-1", "Ada", "server-1")
      VoiceSessionRegistry.reconcile_snapshot([])
      assert VoiceSessionRegistry.participants("server-1") == []

      VoiceSessionRegistry.reconcile_snapshot([
        %{identity: "server-user-1", room_name: "voice:room-1", name: "Ada", server_id: nil}
      ])

      assert [%{"participant_id" => "server-user-1", "room_id" => "room-1"}] =
               VoiceSessionRegistry.participants("server-1")
    end

    test "comes from the room for someone LiveKit reports first" do
      VoiceSessionRegistry.switch("server-user-1", "voice:room-1", "Ada", "server-1")

      VoiceSessionRegistry.reconcile_snapshot([
        %{identity: "server-user-1", room_name: "voice:room-1", name: "Ada", server_id: nil},
        %{identity: "server-user-2", room_name: "voice:room-1", name: "Bea", server_id: nil}
      ])

      assert ["server-user-1", "server-user-2"] =
               "server-1"
               |> VoiceSessionRegistry.participants()
               |> Enum.map(& &1["participant_id"])
               |> Enum.sort()
    end

    test "is also learnt from replicated events" do
      VoiceSessionRegistry.replicate_presence(%{
        "event_type" => "voice.participant_joined",
        "event_id" => "server-join",
        "occurred_at" => "2026-11-01T16:00:00Z",
        "server_id" => "server-1",
        "room_id" => "room-1",
        "participant_id" => "server-user-1",
        "name" => "Ada"
      })

      VoiceSessionRegistry.reconcile_snapshot([
        %{identity: "server-user-2", room_name: "voice:room-1", name: "Bea", server_id: nil}
      ])

      assert [%{"participant_id" => "server-user-2"}] =
               VoiceSessionRegistry.participants("server-1")
    end
  end

  defp millisecond_iso(timestamp) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)
    datetime |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
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
