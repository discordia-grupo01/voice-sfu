defmodule DiscordiaSignaling.Events.ReplicaConsumerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.ReplicaConsumer

  defmodule UnavailableStore do
    def apply_event(_routing_key, _event), do: {:error, :unavailable}
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
end
