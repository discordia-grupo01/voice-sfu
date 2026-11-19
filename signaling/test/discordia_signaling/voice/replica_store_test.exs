defmodule DiscordiaSignaling.Voice.ReplicaStoreTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Voice.ReplicaStore

  test "returns unavailable while the database connection is down" do
    state = %{conn: nil}

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call(:ping, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:enqueue_outbox, %{}}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:pending_outbox, 10}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:mark_outbox_published, "event-1"}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call(
               {:begin_consumption, "event-1", "voice.test", "{}"},
               self(),
               state
             )

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call(
               {:complete_consumption, "event-1", "processed", nil},
               self(),
               state
             )

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call(
               {:next_consumption_attempt, "event-1", nil},
               self(),
               state
             )

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:newer_version, "user-1", 1}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:record_version, "user-1", 1}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:apply, "servers.role_updated", %{}}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:authorize, "channel-1", "user-1"}, self(), state)
  end

  test "returns not_ready while initialization has not established the database" do
    state = %{conn: nil, ready: false, url: "postgres://127.0.0.1:1/discordia_voice"}

    assert {:reply, {:error, :not_ready}, ^state} =
             ReplicaStore.handle_call(:ping, self(), state)

    assert {:reply, {:error, :not_ready}, ^state} =
             ReplicaStore.handle_call({:pending_outbox, 100}, self(), state)
  end

  test "rejects invalid persistent version subjects before querying PostgreSQL" do
    state = %{conn: :stand_in}

    assert {:reply, {:error, :invalid_subject}, ^state} =
             ReplicaStore.handle_call({:newer_version, {:invalid, "subject"}, 1}, self(), state)

    assert {:reply, {:error, :invalid_subject}, ^state} =
             ReplicaStore.handle_call({:record_version, {:invalid, "subject"}, 1}, self(), state)
  end

  test "reconnects after the database process goes down" do
    state = %{conn: :old_connection, ready: true}

    assert {:noreply, %{conn: nil}} =
             ReplicaStore.handle_info({:DOWN, make_ref(), :process, self(), :closed}, state)

    assert_receive :connect
  end

  test "schedules a reconnect when PostgreSQL cannot be reached" do
    state = %{conn: nil, url: "postgres://127.0.0.1:1/discordia_voice"}

    assert {:noreply, next_state} = ReplicaStore.handle_info(:connect, state)
    assert next_state.conn == nil
    assert next_state.ready == false
  end
end
