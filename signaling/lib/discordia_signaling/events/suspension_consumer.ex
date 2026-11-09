defmodule DiscordiaSignaling.Events.SuspensionConsumer do
  @moduledoc """
  Removes from voice whoever admin suspended.

  Consumes `admin.user_suspended` and `admin.server_suspended`, verifies the HMAC
  signature and, when the event carries a version newer than the last one
  handled for that user or server, acts on whoever was already connected:

    * a suspended user is taken out of their room with the same operation used
      by `servers.channel_access_revoked`, and their cached server memberships
      are dropped (see `MembershipCache`);
    * a suspended server has all its voice rooms closed, with the operation
      `servers.server_deleted` uses, and the cached memberships of that server
      are dropped. The event names no channel, so the rooms come from
      `VoiceSessionRegistry.rooms_of_server/1`.

  Entry to voice is blocked by `servers` when the LiveKit token is requested;
  this consumer only handles people who were already connected.
  `admin.user_reactivated` needs no action here, and `admin.server_reactivated`
  only records its version, so that an older suspension arriving late can't
  expel people who already came back.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.{AdminSignature, DeadLetter, RabbitMQ, SuspensionVersions}
  alias DiscordiaSignaling.Log
  alias DiscordiaSignaling.Tracing
  alias DiscordiaSignaling.Voice.{MembershipCache, VoiceSessionRegistry}

  @suspended_key "admin.user_suspended"
  @server_suspended_key "admin.server_suspended"
  @server_reactivated_key "admin.server_reactivated"
  @routing_keys [@suspended_key, @server_suspended_key, @server_reactivated_key]
  @default_exchange "discordia.events"
  @default_queue "voice.signaling"

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :rabbitmq_url),
      exchange: Keyword.get(opts, :exchange, @default_exchange),
      queue: Keyword.get(opts, :queue, @default_queue),
      secret: Keyword.get(opts, :hmac_secret, ""),
      connection: nil,
      channel: nil,
      attempts: %{}
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, connection, channel} ->
        Process.monitor(connection.pid)
        Logger.info("voice_suspension_consumer_connected", queue: state.queue)
        {:noreply, %{state | connection: connection, channel: channel}}

      {:error, reason} ->
        Logger.warning("voice_suspension_consumer_connect_failed",
          reason: Log.reason(reason),
          queue: state.queue,
          exchange: state.exchange
        )

        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_suspension_consumer_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    attempts =
      Tracing.consumer_span(meta, state.queue, fn ->
        result = process_payload(meta.routing_key, payload, state.secret)
        Tracing.mark_outcome(result)
        DeadLetter.finish(result, state, meta, payload)
      end)

    {:noreply, %{state | attempts: attempts}}
  end

  @impl true
  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}
  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}
  def handle_info({:basic_cancel, _meta}, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{connection: nil}), do: :ok

  def terminate(_reason, %{connection: connection}) do
    try do
      AMQP.Connection.close(connection)
    catch
      :exit, _ -> :ok
    end
  end

  @spec process_payload(String.t(), binary(), String.t() | nil) :: :ack | :retry
  def process_payload(routing_key, payload, secret) do
    case Jason.decode(payload) do
      {:ok, %{} = event} -> handle_event(routing_key, event, secret)
      _ -> :ack
    end
  end

  defp handle_event(routing_key, event, secret) do
    if AdminSignature.verify(routing_key, event, secret) do
      routing_key |> parse_event(event) |> apply_event()
    else
      Logger.warning("voice_suspension_invalid_signature",
        event_id: Map.get(event, "event_id"),
        routing_key: routing_key
      )

      :ack
    end
  end

  defp apply_event({:suspend_user, user_id, version}) do
    if SuspensionVersions.newer?(user_id, version) do
      # Before anything that can fail and be retried: a membership confirmed
      # before the suspension must not keep answering for up to its TTL.
      MembershipCache.forget_user(user_id)

      case remove_from_room(user_id) do
        :ok ->
          SuspensionVersions.record(user_id, version)
          :ack

        {:error, _reason} ->
          :retry
      end
    else
      :ack
    end
  end

  defp apply_event({:suspend_server, server_id, version}) do
    key = {:server, server_id}

    if SuspensionVersions.newer?(key, version) do
      # Before anything that can fail and be retried, like the user case.
      MembershipCache.forget_server(server_id)

      case close_server_rooms(server_id) do
        {:ok, closed} ->
          SuspensionVersions.record(key, version)
          Logger.info("voice_server_suspended", server_id: server_id, rooms_closed: closed)
          :ack

        {:error, _reason} ->
          :retry
      end
    else
      :ack
    end
  end

  defp apply_event({:reactivate_server, server_id, version}) do
    SuspensionVersions.record({:server, server_id}, version)
    :ack
  end

  defp apply_event({:error, _reason}), do: :ack

  # Every room is attempted even if one fails, so a LiveKit hiccup on one room
  # doesn't leave the others open; the whole event is retried afterwards.
  defp close_server_rooms(server_id) do
    results =
      server_id
      |> VoiceSessionRegistry.rooms_of_server()
      |> Enum.map(&VoiceSessionRegistry.close_room/1)

    if Enum.all?(results, &(&1 == :ok)),
      do: {:ok, length(results)},
      else: {:error, :livekit_unavailable}
  end

  defp remove_from_room(user_id) do
    case VoiceSessionRegistry.active_room(user_id) do
      nil -> :ok
      room_name -> VoiceSessionRegistry.leave(user_id, room_name)
    end
  end

  defp parse_event(@suspended_key, %{"user_id" => user_id, "version" => version})
       when is_binary(user_id) and user_id != "" and is_integer(version) do
    {:suspend_user, user_id, version}
  end

  defp parse_event(@server_suspended_key, event), do: parse_server_event(:suspend_server, event)

  defp parse_event(@server_reactivated_key, event),
    do: parse_server_event(:reactivate_server, event)

  defp parse_event(_routing_key, _event), do: {:error, :invalid_event}

  defp parse_server_event(action, %{"server_id" => server_id, "version" => version})
       when is_binary(server_id) and server_id != "" and is_integer(version) and version >= 1 do
    {action, server_id, version}
  end

  defp parse_server_event(_action, _event), do: {:error, :invalid_event}

  defp connect(state) do
    with {:ok, connection} <- RabbitMQ.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(connection),
         :ok <- AMQP.Exchange.declare(channel, state.exchange, :topic, durable: true),
         {:ok, _} <- AMQP.Queue.declare(channel, state.queue, durable: true),
         :ok <- DeadLetter.declare(channel, state.queue),
         :ok <- bind(channel, state),
         {:ok, _} <- AMQP.Basic.consume(channel, state.queue) do
      {:ok, connection, channel}
    end
  end

  defp bind(channel, state) do
    Enum.reduce_while(@routing_keys, :ok, fn key, :ok ->
      case AMQP.Queue.bind(channel, state.queue, state.exchange, routing_key: key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
