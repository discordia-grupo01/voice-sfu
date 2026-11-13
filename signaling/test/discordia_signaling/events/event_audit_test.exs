defmodule DiscordiaSignaling.Events.EventAuditTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.EventAudit

  defmodule Store do
    def begin_consumption(_event_id, _event_type, _payload) do
      Application.get_env(:discordia_signaling, :test_audit_begin, :new)
    end

    def complete_consumption(event_id, status, error) do
      send(self(), {:audit_completed, event_id, status, error})
      Application.get_env(:discordia_signaling, :test_audit_complete, :ok)
    end
  end

  setup do
    previous_store = Application.get_env(:discordia_signaling, :voice_event_store)
    previous_begin = Application.get_env(:discordia_signaling, :test_audit_begin)
    previous_complete = Application.get_env(:discordia_signaling, :test_audit_complete)
    Application.put_env(:discordia_signaling, :voice_event_store, Store)

    on_exit(fn ->
      restore(:voice_event_store, previous_store)
      restore(:test_audit_begin, previous_begin)
      restore(:test_audit_complete, previous_complete)
    end)

    :ok
  end

  test "records and completes a new event" do
    assert :ack =
             EventAudit.process("voice.participant_joined", valid_payload(), fn -> :ack end)

    assert_receive {:audit_completed, "event-1", "processed", nil}
  end

  test "reprocesses failed events and records the error" do
    assert :retry =
             EventAudit.process("voice.participant_joined", valid_payload(), fn -> :retry end)

    assert_receive {:audit_completed, "event-1", "failed", ":retry"}
  end

  test "does not execute an already processed event" do
    Application.put_env(:discordia_signaling, :test_audit_begin, :processed)

    assert :ack =
             EventAudit.process("voice.participant_joined", valid_payload(), fn ->
               raise "already processed"
             end)

    refute_received {:audit_completed, _, _, _}
  end

  test "retries when the audit database is unavailable" do
    Application.put_env(:discordia_signaling, :test_audit_begin, {:error, :unavailable})

    assert :retry =
             EventAudit.process("voice.participant_joined", valid_payload(), fn -> :ack end)
  end

  test "retries when completing the audit fails" do
    Application.put_env(:discordia_signaling, :test_audit_complete, {:error, :unavailable})

    assert :retry =
             EventAudit.process("voice.participant_joined", valid_payload(), fn -> :ack end)

    assert_receive {:audit_completed, "event-1", "processed", nil}
  end

  test "acknowledges malformed events because they cannot be audited" do
    assert :ack = EventAudit.process("voice.participant_joined", "not-json", fn -> :retry end)

    assert :ack =
             EventAudit.process("voice.participant_joined", ~s({"event_id":""}), fn -> :retry end)
  end

  defp valid_payload do
    Jason.encode!(%{"event_id" => "event-1", "value" => "payload"})
  end

  defp restore(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
