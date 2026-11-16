defmodule DiscordiaSignaling.Events.SuspensionVersions do
  @moduledoc """
  Persists moderation versions in PostgreSQL so duplicate suppression survives
  process restarts and does not depend on local memory.
  """

  alias DiscordiaSignaling.Voice.ReplicaStore

  @spec newer?(term(), integer()) :: {:ok, boolean()} | {:error, term()}
  def newer?(key, version), do: store().newer_version(key, version)

  @spec record(term(), integer()) :: :ok | {:error, term()}
  def record(key, version), do: store().record_version(key, version)

  defp store do
    Application.get_env(:discordia_signaling, :voice_event_store, ReplicaStore)
  end
end
