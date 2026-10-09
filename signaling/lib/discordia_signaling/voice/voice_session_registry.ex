defmodule DiscordiaSignaling.Voice.VoiceSessionRegistry do
  @moduledoc "Tracks the single active voice room for each authenticated identity."

  use GenServer

  @pubsub DiscordiaSignaling.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec switch(String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def switch(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    GenServer.call(__MODULE__, {:switch, identity, room_name})
  end

  @spec leave(String.t(), String.t()) :: :ok | {:error, atom()}
  def leave(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    GenServer.call(__MODULE__, {:leave, identity, room_name})
  end

  @spec close_room(String.t()) :: :ok | {:error, atom()}
  def close_room(room_name) when is_binary(room_name) do
    GenServer.call(__MODULE__, {:close_room, room_name})
  end

  @spec active_room(String.t()) :: String.t() | nil
  def active_room(identity) when is_binary(identity) do
    GenServer.call(__MODULE__, {:active_room, identity})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:switch, identity, room_name}, _from, state) do
    previous_room = Map.get(state, identity)

    case disconnect_previous(previous_room, room_name, identity) do
      :ok ->
        broadcast_replacement(previous_room, room_name, identity)
        {:reply, {:ok, previous_room}, Map.put(state, identity, room_name)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:leave, identity, room_name}, _from, state) do
    case Map.get(state, identity) do
      ^room_name ->
        case room_service().remove_participant(room_name, identity) do
          result when result in [:ok, {:error, :not_found}] ->
            {:reply, :ok, Map.delete(state, identity)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:close_room, room_name}, _from, state) do
    case room_service().delete_room(room_name) do
      result when result in [:ok, {:error, :not_found}] ->
        {:reply, :ok, Map.reject(state, fn {_identity, active} -> active == room_name end)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active_room, identity}, _from, state) do
    {:reply, Map.get(state, identity), state}
  end

  defp disconnect_previous(nil, _room_name, _identity), do: :ok
  defp disconnect_previous(room_name, room_name, _identity), do: :ok

  defp disconnect_previous(previous_room, _room_name, identity) do
    case room_service().remove_participant(previous_room, identity) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  defp broadcast_replacement(nil, _room_name, _identity), do: :ok

  defp broadcast_replacement(previous_room, room_name, _identity) when previous_room == room_name,
    do: :ok

  defp broadcast_replacement(previous_room, room_name, identity) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice:#{identity}",
      {:voice_session_replaced, identity, previous_room, room_name}
    )
  end

  defp room_service do
    Application.get_env(
      :discordia_signaling,
      :livekit_room_service,
      DiscordiaSignaling.Voice.LiveKitRoomService
    )
  end
end
