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
             ReplicaStore.handle_call({:apply, "servers.role_updated", %{}}, self(), state)

    assert {:reply, {:error, :unavailable}, ^state} =
             ReplicaStore.handle_call({:authorize, "channel-1", "user-1"}, self(), state)
  end

  test "reconnects after the database process goes down" do
    state = %{conn: :old_connection}

    assert {:noreply, %{conn: nil}} =
             ReplicaStore.handle_info({:DOWN, make_ref(), :process, self(), :closed}, state)

    assert_receive :connect
  end

  test "schedules a reconnect when PostgreSQL cannot be reached" do
    state = %{conn: nil, url: "postgres://127.0.0.1:1/discordia_voice"}

    assert {:noreply, %{conn: nil}} = ReplicaStore.handle_info(:connect, state)
    assert_receive :connect, 1_500
  end
end
