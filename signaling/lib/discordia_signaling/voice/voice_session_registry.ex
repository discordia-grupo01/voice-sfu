defmodule DiscordiaSignaling.Voice.VoiceSessionRegistry do
  @moduledoc """
  Tracks active voice rooms and publishes participant presence changes.
  """

  use GenServer

  @pubsub DiscordiaSignaling.PubSub
  @table :voice_sessions
  @starts_table :voice_room_starts
  @room_servers_table :voice_room_servers
  @default_reconcile_grace_ms 15_000

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
    previous_room = identity |> lookup() |> room_name()

    case disconnect_previous(previous_room, room_name, identity) do
      :ok ->
        GenServer.call(__MODULE__, {:switch, identity, room_name, display_name, server_id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec leave(String.t(), String.t()) :: :ok | {:error, atom()}
  def leave(identity, room_name) when is_binary(identity) and is_binary(room_name) do
    case lookup(identity) do
      %{room_name: ^room_name} ->
        case room_service().remove_participant(room_name, identity) do
          result when result in [:ok, {:error, :not_found}] ->
            GenServer.call(__MODULE__, {:leave, identity, room_name})

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @spec close_room(String.t()) :: :ok | {:error, atom()}
  def close_room(room_name) when is_binary(room_name) do
    case room_service().delete_room(room_name) do
      result when result in [:ok, {:error, :not_found}] ->
        GenServer.call(__MODULE__, {:close_room, room_name})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec active_room(String.t()) :: String.t() | nil
  def active_room(identity) when is_binary(identity) do
    identity |> lookup() |> room_name()
  end

  @spec participants(String.t() | nil) :: [map()]
  def participants(server_id \\ nil) do
    @table
    |> :ets.tab2list()
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
  end

  @spec room_starts() :: %{String.t() => String.t()}
  def room_starts do
    @starts_table
    |> :ets.tab2list()
    |> Map.new()
  end

  @spec room_started_at(String.t()) :: String.t() | nil
  def room_started_at(room_id) when is_binary(room_id) do
    case :ets.lookup(@starts_table, room_id) do
      [{^room_id, started_at}] -> started_at
      [] -> nil
    end
  end

  @spec replicate_presence(map()) :: :ok
  def replicate_presence(event) when is_map(event) do
    GenServer.call(__MODULE__, {:replicate_presence, event})
  end

  @spec reconcile_participant(map()) :: :ok
  def reconcile_participant(participant) when is_map(participant) do
    GenServer.call(__MODULE__, {:reconcile_participant, participant})
  end

  @spec reconcile_snapshot([map()]) :: :ok
  def reconcile_snapshot(participants) when is_list(participants) do
    GenServer.call(__MODULE__, {:reconcile_snapshot, participants})
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@starts_table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@room_servers_table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, state}
  end

  @impl true
  def handle_call({:switch, identity, room_name, display_name, server_id}, _from, state) do
    previous = lookup(identity)
    previous_room = room_name(previous)

    participant = %{
      room_name: room_name,
      server_id: server_id,
      name: display_name,
      occurred_at: now_iso(),
      registered_at: now_ms()
    }

    :ets.insert(@table, {identity, participant})
    remember_room_server(room_name, server_id)
    sync_room_start(room_name, participant.occurred_at)

    if previous_room != room_name do
      sync_room_start(previous_room, participant.occurred_at)
      if previous, do: broadcast_presence(:left, identity, previous)
      broadcast_replacement(previous, room_name, identity)
      broadcast_presence(:joined, identity, participant)
    end

    {:reply, {:ok, previous_room}, state}
  end

  def handle_call({:leave, identity, room_name}, _from, state) do
    case lookup(identity) do
      %{room_name: ^room_name} = participant ->
        :ets.delete(@table, identity)
        sync_room_start(room_name, now_iso())
        broadcast_presence(:left, identity, participant)

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:close_room, room_name}, _from, state) do
    closed =
      for {identity, participant} <- :ets.tab2list(@table),
          room_name(participant) == room_name,
          do: {identity, participant}

    Enum.each(closed, fn {identity, _participant} -> :ets.delete(@table, identity) end)
    sync_room_start(room_name, now_iso())

    Enum.each(closed, fn {identity, participant} ->
      broadcast_presence(:left, identity, participant)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:replicate_presence, event}, _from, state) do
    if apply_presence_event(event) == :applied do
      broadcast_presence_event(event)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(
        {:reconcile_participant,
         %{identity: identity, room_name: room_name, name: name, server_id: server_id}},
        _from,
        state
      )
      when is_binary(identity) and identity != "" and is_binary(room_name) and room_name != "" do
    previous_room = identity |> lookup() |> room_name()
    occurred_at = now_iso()

    server_id = server_id || room_server(room_name)

    :ets.insert(
      @table,
      {identity,
       %{
         room_name: room_name,
         server_id: server_id,
         name: name,
         occurred_at: occurred_at,
         registered_at: now_ms()
       }}
    )

    remember_room_server(room_name, server_id)
    sync_room_start(room_name, occurred_at)
    if previous_room != room_name, do: sync_room_start(previous_room, occurred_at)

    {:reply, :ok, state}
  end

  def handle_call({:reconcile_participant, _participant}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:reconcile_snapshot, participants}, _from, state) do
    active_identities = MapSet.new(participants, & &1.identity)

    removed =
      for {identity, participant} <- :ets.tab2list(@table),
          not MapSet.member?(active_identities, identity),
          not recently_registered?(participant),
          do: {identity, participant}

    Enum.each(removed, fn {identity, _participant} -> :ets.delete(@table, identity) end)

    Enum.each(participants, fn participant ->
      identity = participant.identity
      current = lookup(identity)
      same_room? = current != nil and current.room_name == participant.room_name

      unless current != nil and not same_room? and recently_registered?(current) do
        server_id =
          participant.server_id || (current && current.server_id) ||
            room_server(participant.room_name)

        :ets.insert(
          @table,
          {identity,
           %{
             room_name: participant.room_name,
             server_id: server_id,
             name: participant.name,
             occurred_at: now_iso(),
             registered_at: if(same_room?, do: current[:registered_at], else: now_ms())
           }}
        )

        remember_room_server(participant.room_name, server_id)
      end
    end)

    sync_all_room_starts(participants)

    Enum.each(removed, fn {identity, participant} ->
      broadcast_presence(:left, identity, participant)
    end)

    {:reply, :ok, state}
  end

  defp lookup(identity) do
    case :ets.lookup(@table, identity) do
      [{^identity, participant}] -> participant
      [] -> nil
    end
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp recently_registered?(participant) do
    case participant[:registered_at] do
      registered_at when is_integer(registered_at) ->
        now_ms() - registered_at < reconcile_grace_ms()

      _ ->
        false
    end
  end

  defp reconcile_grace_ms do
    Application.get_env(
      :discordia_signaling,
      :reconcile_grace_ms,
      @default_reconcile_grace_ms
    )
  end

  defp remember_room_server(room_name, server_id)
       when is_binary(room_name) and is_binary(server_id) do
    :ets.insert(@room_servers_table, {room_name, server_id})
  end

  defp remember_room_server(_room_name, _server_id), do: :ok

  defp room_server(room_name) do
    case :ets.lookup(@room_servers_table, room_name) do
      [{^room_name, server_id}] -> server_id
      [] -> nil
    end
  end

  defp sync_room_start(nil, _started_at), do: :ok

  defp sync_room_start(room_name, started_at) do
    if room_occupied?(room_name) do
      :ets.insert_new(@starts_table, {room_id(room_name), to_millisecond_iso(started_at)})
    else
      :ets.delete(@starts_table, room_id(room_name))
    end

    :ok
  end

  defp sync_all_room_starts(snapshot) do
    occupied =
      @table
      |> :ets.tab2list()
      |> MapSet.new(fn {_identity, participant} -> room_id(participant.room_name) end)

    for {room_id, _started_at} <- :ets.tab2list(@starts_table),
        not MapSet.member?(occupied, room_id) do
      :ets.delete(@starts_table, room_id)
    end

    livekit_starts =
      for %{room_name: room_name, room_started_at: started_at} <- snapshot,
          is_binary(started_at),
          into: %{},
          do: {room_id(room_name), started_at}

    now = now_iso()

    Enum.each(occupied, fn room_id ->
      started_at = Map.get(livekit_starts, room_id, now)
      :ets.insert_new(@starts_table, {room_id, to_millisecond_iso(started_at)})
    end)
  end

  defp room_occupied?(room_name) do
    @table
    |> :ets.tab2list()
    |> Enum.any?(fn {_identity, participant} -> participant.room_name == room_name end)
  end

  defp to_millisecond_iso(timestamp) do
    datetime =
      case DateTime.from_iso8601(timestamp) do
        {:ok, datetime, _offset} -> datetime
        _ -> DateTime.utc_now()
      end

    datetime
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
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
    event = presence_event(action, identity, participant)
    broadcast_presence_event(event)
    publisher().publish(event)
  end

  defp presence_event(action, identity, participant) do
    event_type =
      if action == :joined, do: "voice.participant_joined", else: "voice.participant_left"

    occurred_at =
      if action == :joined,
        do: participant.occurred_at,
        else: leave_timestamp(participant.occurred_at)

    %{
      "event_id" => uuid(),
      "event_type" => event_type,
      "server_id" => participant.server_id,
      "room_id" => room_id(participant.room_name),
      "participant_id" => identity,
      "name" => participant.name,
      "occurred_at" => occurred_at
    }
  end

  defp broadcast_presence_event(
         %{
           "room_id" => room_id,
           "server_id" => server_id
         } = event
       )
       when is_binary(room_id) and is_binary(server_id) do
    event = Map.put(event, "room_started_at", room_started_at(room_id))

    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice:#{room_id}",
      {:voice_presence, event}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "voice_server:#{server_id}",
      {:voice_presence, event}
    )
  end

  defp broadcast_presence_event(_event), do: :ok

  defp apply_presence_event(%{
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
    current = lookup(identity)
    applied = newer_event?(current, occurred_at)

    if applied do
      case event_type do
        "voice.participant_joined" ->
          :ets.insert(
            @table,
            {identity,
             %{
               room_name: incoming_room,
               server_id: server_id,
               name: name,
               occurred_at: occurred_at,
               registered_at: now_ms()
             }}
          )

          remember_room_server(incoming_room, server_id)

          sync_room_start(incoming_room, occurred_at)
          previous_room = room_name(current)
          if previous_room != incoming_room, do: sync_room_start(previous_room, occurred_at)

        "voice.participant_left" ->
          if current && room_name(current) == incoming_room do
            :ets.delete(@table, identity)
            sync_room_start(incoming_room, occurred_at)
          end
      end
    end

    if applied, do: :applied, else: :ignored
  end

  defp apply_presence_event(_event), do: :ignored

  defp leave_timestamp(joined_at) do
    joined = parse_datetime(joined_at)
    minimum = DateTime.add(joined, 1, :microsecond)
    now = DateTime.utc_now()
    timestamp = if DateTime.compare(now, minimum) == :lt, do: minimum, else: now

    timestamp
    |> DateTime.to_iso8601()
    |> ensure_after(joined)
  end

  defp ensure_after(timestamp, joined) do
    if DateTime.compare(parse_datetime(timestamp), joined) == :gt do
      timestamp
    else
      joined |> DateTime.add(1, :microsecond) |> DateTime.to_iso8601()
    end
  end

  defp newer_event?(nil, _occurred_at), do: true

  defp newer_event?(participant, occurred_at) do
    DateTime.compare(parse_datetime(participant[:occurred_at]), parse_datetime(occurred_at)) ==
      :lt
  end

  defp parse_datetime(nil), do: DateTime.from_unix!(0)

  defp parse_datetime(value) do
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
