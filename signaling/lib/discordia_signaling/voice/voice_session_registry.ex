defmodule DiscordiaSignaling.Voice.VoiceSessionRegistry do
  @moduledoc "Tracks the single active voice room for each authenticated identity."

  use GenServer

  @pubsub DiscordiaSignaling.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec switch(String.t(), String.t()) :: {:ok, String.t() | nil}
  def switch(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    GenServer.call(__MODULE__, {:switch, identity, room_name})
  end

  @spec leave(String.t(), String.t()) :: :ok
  def leave(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    GenServer.call(__MODULE__, {:leave, identity, room_name})
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

    if previous_room && previous_room != room_name do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "voice:#{identity}",
        {:voice_session_replaced, identity, previous_room, room_name}
      )
    end

    {:reply, {:ok, previous_room}, Map.put(state, identity, room_name)}
  end

  def handle_call({:leave, identity, room_name}, _from, state) do
    next_state =
      case Map.get(state, identity) do
        ^room_name -> Map.delete(state, identity)
        _ -> state
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:active_room, identity}, _from, state) do
    {:reply, Map.get(state, identity), state}
  end
end
