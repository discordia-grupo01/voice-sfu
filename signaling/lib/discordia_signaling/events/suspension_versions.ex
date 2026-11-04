defmodule DiscordiaSignaling.Events.SuspensionVersions do
  @moduledoc """
  In-memory record of the last `admin.*` moderation version handled per subject:
  a user id for `admin.user_suspended` and `{:server, server_id}` for the
  `admin.server_*` events.

  It only discards duplicates while the process lives: it is lost on restart on
  purpose, because this service has no database.
  """

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "True when `version` is greater than the last one recorded for the subject."
  @spec newer?(term(), integer()) :: boolean()
  def newer?(key, version) do
    Agent.get(__MODULE__, fn versions ->
      case Map.fetch(versions, key) do
        {:ok, seen} -> version > seen
        :error -> true
      end
    end)
  end

  @doc "Records `version` for the subject, keeping the highest one seen."
  @spec record(term(), integer()) :: :ok
  def record(key, version) do
    Agent.update(__MODULE__, &Map.update(&1, key, version, fn seen -> max(seen, version) end))
  end
end
