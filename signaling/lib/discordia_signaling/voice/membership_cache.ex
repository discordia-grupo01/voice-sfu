defmodule DiscordiaSignaling.Voice.MembershipCache do
  @moduledoc """
  Short-lived memory of which users the servers API already confirmed as members
  of a server.

  The presence endpoint is polled by every connected client, and each poll used
  to ask the servers API again. Only a positive answer is kept: a user who has
  just joined sees the participants at once, and a failure or a refusal is never
  reused. The cost is that someone who just left a server can keep reading who
  is in its voice channels for up to the TTL; joining a channel is still checked
  on every attempt.

  The table lives in this process but is read and written by the callers.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms 30_000
  @max_entries 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Returns `:ok` from the cache while the entry for `key` is fresh. Otherwise runs
  `fun` and remembers the result if it is `:ok`. Without a key, or with a TTL of
  0, `fun` always runs.
  """
  @spec fetch(term(), non_neg_integer(), (-> :ok | :forbidden | :unavailable)) ::
          :ok | :forbidden | :unavailable
  def fetch(nil, _ttl_ms, fun), do: fun.()
  def fetch(_key, ttl_ms, fun) when ttl_ms <= 0, do: fun.()

  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key) do
      expires_at when is_integer(expires_at) and expires_at > now ->
        :ok

      _ ->
        result = fun.()
        if result == :ok, do: remember(key, now + ttl_ms)
        result
    end
  end

  @doc "Forgets every entry."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def default_ttl_ms, do: @default_ttl_ms

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at}] -> expires_at
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp remember(key, expires_at) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, expires_at})
  rescue
    ArgumentError -> :ok
  end
end
