defmodule DiscordiaSignaling.Events.SuspensionVersions do
  @moduledoc """
  In-memory record of the last `admin.user_suspended` version handled per user.

  It only discards duplicates while the process lives: it is lost on restart on
  purpose, because this service has no database.
  """

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "True when `version` is greater than the last one recorded for the user."
  @spec newer?(String.t(), integer()) :: boolean()
  def newer?(user_id, version) do
    Agent.get(__MODULE__, fn versions ->
      case Map.fetch(versions, user_id) do
        {:ok, seen} -> version > seen
        :error -> true
      end
    end)
  end

  @doc "Records `version` for the user, keeping the highest one seen."
  @spec record(String.t(), integer()) :: :ok
  def record(user_id, version) do
    Agent.update(__MODULE__, &Map.update(&1, user_id, version, fn seen -> max(seen, version) end))
  end
end
