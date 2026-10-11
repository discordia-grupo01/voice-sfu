defmodule DiscordiaSignaling.Voice.VoiceSessionRegistry do
  @moduledoc "Tracks active voice rooms and publishes participant presence changes."

  use GenServer

  @pubsub DiscordiaSignaling.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec switch(String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def switch(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    switch(identity, room_name, identity, nil)
  end

  @spec switch(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, atom()}
  def switch(identity, room_name, display_name, server_id)
      when is_binary(identity) and is_binary(room_name) and is_binary(display_name) do
    GenServer.call(__MODULE__, {:switch, identity, room_name, display_name, server_id})
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

  @spec participants(String.t() | nil) :: [map()]
  def participants(server_id \\ nil) do
    GenServer.call(__MODULE__, {:participants, server_id})
  end

  @spec replicate_presence(map()) :: :ok
  def replicate_presence(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:replicate_presence, event})
  end

  @spec reconcile_participant(map()) :: :ok
  def reconcile_participant(participant) when is_map(participant) do
    GenServer.cast(__MODULE__, {:reconcile_participant, participant})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:switch, identity, room_name, display_name, server_id}, _from, state) do
    previous = Map.get(state, identity)
    previous_room = room_name(previous)

    case disconnect_previous(previous_room, room_name, identity) do
      :ok ->
        participant = %{
          room_name: room_name,
          server_id: server_id,
          name: display_name,
          occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        if previous_room == room_name do
          {:reply, {:ok, previous_room}, Map.put(state, identity, participant)}
        else
          state = remove_participant(state, identity, previous)
          if previous, do: broadcast_presence(:left, identity, previous)
          broadcast_replacement(previous, room_name, identity)
          broadcast_presence(:joined, identity, participant)
          {:reply, {:ok, previous_room}, Map.put(state, identity, participant)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:leave, identity, room_name}, _from, state) do
    case Map.get(state, identity) do
      %{room_name: ^room_name} = participant ->
        case room_service().remove_participant(room_name, identity) do
          result when result in [:ok, {:error, :not_found}] ->
            broadcast_presence(:left, identity, participant)
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
        {removed, remaining} =
          state
          |> Enum.split_with(fn {_identity, participant} ->
            room_name(participant) == room_name
          end)
          |> then(fn {removed, remaining} -> {removed, Map.new(remaining)} end)

        Enum.each(removed, fn {identity, participant} ->
          broadcast_presence(:left, identity, participant)
        end)

        {:reply, :ok, remaining}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active_room, identity}, _from, state) do
    {:reply, room_name(Map.get(state, identity)), state}
  end

  def handle_call({:participants, server_id}, _from, state) do
    participants =
      state
      |> Enum.flat_map(fn {identity, participant} ->
        if server_id == nil or participant.server_id == server_id do
          [
            %{
              "participant_id" => identity,
              "name" => participant.name,
              "room_id" => room_id(participant.room_name)
            }
          ]
        else
          []
        end
      end)

    {:reply, participants, state}
  end

  @impl true
  def handle_cast({:replicate_presence, event}, state) do
    {:noreply, apply_presence_event(state, event)}
  end

  @impl true
  def handle_cast(
        {:reconcile_participant,
         %{identity: identity, room_name: room_name, name: name, server_id: server_id}},
        state
      )
      when is_binary(identity) and identity != "" and is_binary(room_name) and room_name != "" do
    participant = %{
      room_name: room_name,
      server_id: server_id,
      name: name,
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:noreply, Map.put(state, identity, participant)}
  end

  def handle_cast({:reconcile_participant, _participant}, state), do: {:noreply, state}

  defp disconnect_previous(nil, _room_name, _identity), do: :ok
  defp disconnect_previous(room_name, room_name, _identity), do: :ok

  defp disconnect_previous(previous_room, _room_name, identity) do
    case room_service().remove_participant(previous_room, identity) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  defp broadcast_replacement(nil, _room_name, _identity), do: :ok

  defp broadcast_replacement(%{room_name: previous_room}, room_name, _identity)
       when previous_room == room_name,
       do: :ok

  defp broadcast_replacement(%{room_name: previous_room}, room_name, identity) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice:#{identity}",
      {:voice_session_replaced, identity, previous_room, room_name}
    )
  end

  defp broadcast_presence(action, identity, participant) do
    event_type =
      if action == :joined, do: "voice.participant_joined", else: "voice.participant_left"

    event = %{
      "event_id" => uuid(),
      "event_type" => event_type,
      "server_id" => participant.server_id,
      "room_id" => room_id(participant.room_name),
      "participant_id" => identity,
      "name" => participant.name,
      "occurred_at" => participant.occurred_at
    }

    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice:#{room_id(participant.room_name)}",
      {:voice_presence, event}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice_server:#{participant.server_id}",
      {:voice_presence, event}
    )

    publisher().publish(event)
  end

  defp apply_presence_event(state, %{
         "event_type" => event_type,
         "participant_id" => identity,
         "room_id" => room_id,
         "name" => name,
         "server_id" => server_id,
         "occurred_at" => occurred_at
       })
       when event_type in ["voice.participant_joined", "voice.participant_left"] and
              is_binary(identity) and identity != "" and is_binary(room_id) and room_id != "" and
              is_binary(occurred_at) do
    incoming_room = "voice:" <> room_id
    current = Map.get(state, identity)

    if newer_event?(current, occurred_at) do
      case event_type do
        "voice.participant_joined" ->
          Map.put(state, identity, %{
            room_name: incoming_room,
            server_id: server_id,
            name: name,
            occurred_at: occurred_at
          })

        "voice.participant_left" ->
          if current && room_name(current) == incoming_room do
            Map.delete(state, identity)
          else
            state
          end
      end
    else
      state
    end
  end

  defp apply_presence_event(state, _event), do: state

  defp newer_event?(nil, _occurred_at), do: true

  defp newer_event?(participant, occurred_at) do
    DateTime.compare(parse_datetime(participant[:occurred_at]), parse_datetime(occurred_at)) ==
      :lt
  end

  defp parse_datetime(value) do
    if is_nil(value) do
      DateTime.from_unix!(0)
    else
      parse_datetime_value(value)
    end
  end

  defp parse_datetime_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.from_unix!(0)
    end
  end

  defp publisher do
    Application.get_env(
      :discordia_signaling,
      :voice_presence_publisher,
      DiscordiaSignaling.Voice.VoicePresencePublisher
    )
  end

  defp remove_participant(state, _identity, nil), do: state
  defp remove_participant(state, identity, _participant), do: Map.delete(state, identity)

  defp room_name(nil), do: nil
  defp room_name(%{room_name: room_name}), do: room_name
  defp room_name(room_name) when is_binary(room_name), do: room_name

  defp room_id("voice:" <> room_id), do: room_id
  defp room_id(room_name), do: room_name

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    "#{hex(a, 8)}-#{hex(b, 4)}-#{hex(c, 4)}-#{hex(d, 4)}-#{hex(e, 12)}"
  end

  defp hex(value, size), do: value |> Integer.to_string(16) |> String.pad_leading(size, "0")

  defp room_service do
    Application.get_env(
      :discordia_signaling,
      :livekit_room_service,
      DiscordiaSignaling.Voice.LiveKitRoomService
    )
  end
end
