defmodule DiscordiaSignaling.Events.EventAudit do
  @moduledoc """
  Persists incoming voice events before processing them.

  A pending record is intentionally eligible for processing again. This makes
  a crash between recording and applying an event recoverable while a
  processed record makes redelivery idempotent.
  """

  alias DiscordiaSignaling.Voice.ReplicaStore

  @spec process(String.t(), binary(), (-> :ack | :retry | :invalid | term())) ::
          :ack | :retry
  def process(routing_key, payload, fun) when is_binary(routing_key) and is_binary(payload) do
    event_id = audit_id(payload)

    with {:new, ^event_id} <- begin(event_id, routing_key, payload) do
      result =
        case Jason.decode(payload) do
          {:ok, %{"event_id" => id}} when is_binary(id) and id != "" -> normalize(fun.())
          _ -> :invalid
        end

      status =
        if result == :ack,
          do: "processed",
          else: if(result == :invalid, do: "invalid", else: "failed")

      case event_store().complete_consumption(event_id, status, error(result)) do
        :ok -> result_to_ack(result)
        {:error, _reason} -> :retry
      end
    else
      {:processed, _} -> :ack
      {:error, _reason} -> :retry
    end
  end

  defp begin(event_id, routing_key, payload) do
    case event_store().begin_consumption(event_id, routing_key, payload) do
      :new -> {:new, event_id}
      :processed -> {:processed, event_id}
      result -> result
    end
  end

  defp normalize(:ack), do: :ack
  defp normalize(:retry), do: :retry
  defp normalize(:invalid), do: :retry
  defp normalize(_other), do: :retry

  defp error(:ack), do: nil
  defp error(:invalid), do: "invalid_event"
  defp error(result), do: inspect(result)

  defp result_to_ack(:invalid), do: :ack
  defp result_to_ack(result), do: result

  defp audit_id(payload) do
    case Jason.decode(payload) do
      {:ok, %{"event_id" => event_id}} when is_binary(event_id) and event_id != "" -> event_id
      _ -> "invalid:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
    end
  end

  defp event_store do
    Application.get_env(
      :discordia_signaling,
      :voice_event_store,
      ReplicaStore
    )
  end
end
