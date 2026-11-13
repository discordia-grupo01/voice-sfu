defmodule DiscordiaSignaling.Voice.ReplicaStoreIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias DiscordiaSignaling.Voice.ReplicaStore

  setup do
    database_url =
      System.get_env(
        "VOICE_REPLICA_DATABASE_URL",
        "postgres://discordia:discordia@localhost:5432/discordia_voice"
      )

    previous = Application.get_env(:discordia_signaling, :replica)
    previous_events = Application.get_env(:discordia_signaling, :voice_events)
    Application.put_env(:discordia_signaling, :replica, database_url: database_url)
    Application.put_env(:discordia_signaling, :voice_events, database_url: events_database_url())

    Supervisor.terminate_child(DiscordiaSignaling.Supervisor, ReplicaStore)
    {:ok, _pid} = Supervisor.restart_child(DiscordiaSignaling.Supervisor, ReplicaStore)

    on_exit(fn ->
      restore(:replica, previous)
      restore(:voice_events, previous_events)
      Supervisor.terminate_child(DiscordiaSignaling.Supervisor, ReplicaStore)
      Supervisor.restart_child(DiscordiaSignaling.Supervisor, ReplicaStore)
    end)

    available? =
      try do
        ReplicaStore.ping() == :ok
      catch
        :exit, _ -> false
      end

    if not available? do
      {:ok, available?: false}
    else
      {:ok, available?: true}
    end
  end

  test "persists outbox events and consumed-event status", %{available?: available?} do
    run_if_available(available?, fn ->
      suffix = Integer.to_string(System.unique_integer([:positive]))
      event_id = "outbox-" <> suffix
      event = %{"event_id" => event_id, "event_type" => "voice.test", "value" => "ok"}

      assert :ok = ReplicaStore.enqueue_outbox(event)
      assert :ok = ReplicaStore.enqueue_outbox(event)
      assert {:ok, pending} = ReplicaStore.pending_outbox()
      assert Enum.any?(pending, &(&1.event_id == event_id))

      assert :ok = ReplicaStore.mark_outbox_published(event_id)
      assert {:ok, pending} = ReplicaStore.pending_outbox()
      refute Enum.any?(pending, &(&1.event_id == event_id))

      payload = Jason.encode!(event)
      assert :new = ReplicaStore.begin_consumption(event_id, event["event_type"], payload)
      assert :ok = ReplicaStore.complete_consumption(event_id, "processed")
      assert :processed = ReplicaStore.begin_consumption(event_id, event["event_type"], payload)
    end)
  end

  test "applies snapshots and ignores an older event for the same entity", %{
    available?: available?
  } do
    run_if_available(available?, &assert_snapshot_application/0)
  end

  test "keeps a tombstone when the database is available", %{available?: available?} do
    run_if_available(available?, &assert_tombstone/0)
  end

  defp assert_snapshot_application do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    server_id = "server-" <> suffix
    channel_id = "channel-" <> suffix
    role_id = "role-" <> suffix
    user_id = "user-" <> suffix

    assert {:ok, :applied} =
             apply_event("servers.channel_created", %{
               "event_id" => "channel-event-" <> suffix,
               "occurred_at" => "2026-11-01T10:00:00Z",
               "server_id" => server_id,
               "channel_id" => channel_id,
               "name" => "Voice",
               "kind" => "voice"
             })

    assert {:ok, :applied} =
             apply_event("servers.role_updated", %{
               "event_id" => "role-event-" <> suffix,
               "occurred_at" => "2026-11-01T10:01:00Z",
               "server_id" => server_id,
               "role_id" => role_id,
               "permissions" => ["CONNECT"],
               "is_everyone" => false
             })

    assert {:ok, :applied} =
             apply_event("servers.member_roles_updated", %{
               "event_id" => "member-event-" <> suffix,
               "occurred_at" => "2026-11-01T10:02:00Z",
               "server_id" => server_id,
               "user_id" => user_id,
               "role_ids" => [role_id]
             })

    assert {:ok, :applied} =
             apply_event("servers.owner_updated", %{
               "event_id" => "owner-event-" <> suffix,
               "occurred_at" => "2026-11-01T10:03:00Z",
               "server_id" => server_id,
               "owner_id" => "another-user"
             })

    assert {:ok, [^server_id, "voice", "another-user", role_ids, _roles, _overrides, nil, nil]} =
             ReplicaStore.authorize(channel_id, user_id)

    assert role_ids == [role_id]

    assert {:ok, :stale} =
             apply_event("servers.role_updated", %{
               "event_id" => "old-role-event-" <> suffix,
               "occurred_at" => "2026-11-01T09:00:00Z",
               "server_id" => server_id,
               "role_id" => role_id,
               "permissions" => [],
               "is_everyone" => false
             })

    assert {:ok, [^server_id, "voice", "another-user", ^role_ids, _roles, _overrides, nil, nil]} =
             ReplicaStore.authorize(channel_id, user_id)
  end

  defp assert_tombstone do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    channel_id = "deleted-channel-" <> suffix
    server_id = "deleted-server-" <> suffix

    assert {:ok, :applied} =
             apply_event("servers.channel_created", %{
               "event_id" => "created-" <> suffix,
               "occurred_at" => "2026-11-01T10:00:00Z",
               "server_id" => server_id,
               "channel_id" => channel_id,
               "name" => "Voice",
               "kind" => "voice"
             })

    assert {:ok, :applied} =
             apply_event("servers.channel_deleted", %{
               "event_id" => "deleted-" <> suffix,
               "occurred_at" => "2026-11-01T11:00:00Z",
               "server_id" => server_id,
               "channel_id" => channel_id
             })

    assert {:ok, :stale} =
             apply_event("servers.channel_created", %{
               "event_id" => "late-created-" <> suffix,
               "occurred_at" => "2026-11-01T10:30:00Z",
               "server_id" => server_id,
               "channel_id" => channel_id,
               "name" => "Resurrected",
               "kind" => "voice"
             })

    assert {:error, :forbidden} = ReplicaStore.authorize(channel_id, "user-" <> suffix)
  end

  defp run_if_available(true, test), do: test.()

  defp run_if_available(false, _test) do
    IO.puts("ReplicaStore integration skipped: VOICE_REPLICA_DATABASE_URL is unavailable")
  end

  defp apply_event(routing_key, event), do: ReplicaStore.apply_event(routing_key, event)

  defp events_database_url do
    System.get_env(
      "VOICE_EVENTS_DATABASE_URL",
      "postgres://discordia:discordia@localhost:5432/discordia_voice"
    )
  end

  defp restore(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
