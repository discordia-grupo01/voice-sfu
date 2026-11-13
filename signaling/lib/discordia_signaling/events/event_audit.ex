defmodule DiscordiaSignaling.Events.EventAudit do
  @moduledoc """
  Persists incoming voice events before processing them.

  A pending record is intentionally eligible for processing again. This makes
  a crash between recording and applying an event recoverable while a
  processed record makes redelivery idempotent.
  """

  alias DiscordiaSignaling.Voice.ReplicaStore

  @spec process(String.t(), binary(), (-> :ack | :retry | term())) :: :ack | :retry
  def process(routing_key, payload, fun) when is_binary(routing_key) and is_binary(payload) do
    with {:ok, %{"event_id" => event_id}} <- Jason.decode(payload),
         true <- is_binary(event_id) and event_id != "",
         {:new, _} <- begin(event_id, routing_key, payload) do
      result = normalize(fun.())
      status = if result == :ack, do: "processed", else: "failed"

      case ReplicaStore.complete_consumption(event_id, status, error(result)) do
        :ok -> result
        {:error, _reason} -> :retry
      end
    else
      {:processed, _} -> :ack
      {:error, _reason} -> :retry
      _ -> :ack
    end
  end

  defp begin(event_id, routing_key, payload) do
    case ReplicaStore.begin_consumption(event_id, routing_key, payload) do
      :new -> {:new, event_id}
      :processed -> {:processed, event_id}
      result -> result
    end
  end

  defp normalize(:ack), do: :ack
  defp normalize(:retry), do: :retry
  defp normalize(_other), do: :retry

  defp error(:ack), do: nil
  defp error(result), do: inspect(result)
end
