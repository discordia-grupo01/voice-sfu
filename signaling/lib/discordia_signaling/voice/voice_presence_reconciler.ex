defmodule DiscordiaSignaling.Voice.VoicePresenceReconciler do
  @moduledoc """
  Rebuilds the local signaling snapshot from LiveKit after a node starts.

  RabbitMQ distributes future changes; LiveKit is the source of truth for
  participants that are currently connected. The same snapshot ends private
  calls whose participants left without hanging up.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Voice.{LiveKitRoomService, PrivateCall, VoiceSessionRegistry}

  @reconcile_interval 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :reconcile)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    case room_service().active_participants() do
      {:ok, participants} ->
        VoiceSessionRegistry.reconcile_snapshot(participants)
        PrivateCall.reconcile(participants)
        Process.send_after(self(), :reconcile, @reconcile_interval)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("voice_presence_reconcile_failed reason=#{inspect(reason)}")
        Process.send_after(self(), :reconcile, 1_000)
        {:noreply, state}
    end
  end

  defp room_service do
    Application.get_env(
      :discordia_signaling,
      :livekit_room_service,
      LiveKitRoomService
    )
  end
end
