defmodule DiscordiaSignaling.Events.ReplicaConsumerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.ReplicaConsumer

  defmodule UnavailableStore do
    def apply_event(_routing_key, _event), do: {:error, :unavailable}
  end

  defmodule AppliedStore do
    def apply_event(_routing_key, _event), do: {:ok, :applied}
  end

  defmodule StaleStore do
    def apply_event(_routing_key, _event), do: :stale
  end

  defmodule InvalidStore do
    def apply_event(_routing_key, _event), do: {:ok, :invalid}
  end

  setup do
    previous = Application.get_env(:discordia_signaling, :replica_store)
    Application.put_env(:discordia_signaling, :replica_store, UnavailableStore)

    on_exit(fn ->
      if previous do
        Application.put_env(:discordia_signaling, :replica_store, previous)
      else
        Application.delete_env(:discordia_signaling, :replica_store)
      end
    end)

    :ok
  end

  test "sends malformed JSON to the invalid-event path" do
    assert :invalid = ReplicaConsumer.process_payload("servers.role_updated", "not-json")
  end

  test "initializes and retries a broker connection" do
    assert {:ok, state} =
             ReplicaConsumer.init(
               rabbitmq_url: "amqp://127.0.0.1:1",
               exchange: "discordia.events",
               queue: "voice.replica.test"
             )

    assert {:noreply, next_state} = ReplicaConsumer.handle_info(:connect, state)
    assert next_state.connection == nil
    assert_receive :connect, 1_500
  end

  test "clears a failed broker connection and reconnects" do
    state = %{connection: :connection, channel: :channel, attempts: %{}, queue: "q"}

    assert {:noreply, %{connection: nil, channel: nil}} =
             ReplicaConsumer.handle_info(
               {:DOWN, make_ref(), :process, self(), :closed},
               state
             )

    assert_receive :connect
  end

  test "rejects unknown routing keys" do
    payload = Jason.encode!(%{"event_id" => "event-1", "occurred_at" => "2026-11-01T10:00:00Z"})

    assert :invalid = ReplicaConsumer.process_payload("servers.unknown", payload)
  end

  test "rejects events with malformed timestamps" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-2",
        "occurred_at" => "not-a-timestamp",
        "server_id" => "server-1",
        "role_id" => "role-1",
        "permissions" => ["CONNECT"],
        "is_everyone" => false
      })

    assert :invalid = ReplicaConsumer.process_payload("servers.role_updated", payload)
  end

  test "rejects events without an event id" do
    payload =
      Jason.encode!(%{
        "occurred_at" => "2026-11-01T10:00:00Z",
        "server_id" => "server-1",
        "role_id" => "role-1",
        "permissions" => ["CONNECT"],
        "is_everyone" => false
      })

    assert :invalid = ReplicaConsumer.process_payload("servers.role_updated", payload)
  end

  test "does not acknowledge a valid event while the replica database is unavailable" do
    payload =
      Jason.encode!(%{
        "event_id" => "event-3",
        "occurred_at" => "2026-11-01T10:00:00Z",
        "server_id" => "server-1",
        "role_id" => "role-1",
        "permissions" => ["CONNECT"],
        "is_everyone" => false
      })

    assert :database_retry = ReplicaConsumer.process_payload("servers.role_updated", payload)
  end

  test "acknowledges an applied event" do
    use_store(AppliedStore)

    assert :ack = ReplicaConsumer.process_payload("servers.role_updated", valid_payload())
  end

  test "acknowledges a profile backfill event" do
    use_store(AppliedStore)

    payload =
      Jason.encode!(%{
        "event_id" => "profile-event",
        "occurred_at" => "2026-11-01T10:00:00Z",
        "user_id" => "699ee337-a4cd-40de-89a4-a0c66a67d25f",
        "version" => 1,
        "name" => "Member",
        "avatar_url" => "",
        "description" => "",
        "status_text" => "",
        "status_emoji" => ""
      })

    assert :ack = ReplicaConsumer.process_payload("users.profile_updated", payload)
  end

  test "acknowledges a stale event" do
    use_store(StaleStore)

    assert :ack = ReplicaConsumer.process_payload("servers.role_updated", valid_payload())
  end

  test "sends an invalid replica result to the invalid-event path" do
    use_store(InvalidStore)

    assert :invalid = ReplicaConsumer.process_payload("servers.role_updated", valid_payload())
  end

  defp valid_payload do
    Jason.encode!(%{
      "event_id" => "event-valid",
      "occurred_at" => "2026-11-01T10:00:00Z",
      "server_id" => "server-1",
      "role_id" => "role-1",
      "permissions" => ["CONNECT"],
      "is_everyone" => false
    })
  end

  defp use_store(store), do: Application.put_env(:discordia_signaling, :replica_store, store)
end
