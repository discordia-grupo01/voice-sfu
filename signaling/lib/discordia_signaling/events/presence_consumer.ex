defmodule DiscordiaSignaling.Events.PresenceConsumer do
  @moduledoc """
  Replicates voice presence events from RabbitMQ into this signaling instance.

  Each instance consumes from its own exclusive, server-named queue, so every
  instance receives every presence event instead of RabbitMQ load-balancing it
  between replicas (which happened when replicas shared `VOICE_INSTANCE_ID`).
  The queue is deleted when the connection closes; events missed while
  disconnected are recovered by `VoicePresenceReconciler`.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.{Contract, EventAudit, RabbitMQ}
  alias DiscordiaSignaling.Log
  alias DiscordiaSignaling.Tracing
  alias DiscordiaSignaling.Voice.{PrivateCall, VoiceSessionRegistry}

  @routing_keys ["voice.participant_joined", "voice.participant_left", "voice.private_call"]
  @default_exchange "discordia.events"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :rabbitmq_url),
      exchange: Keyword.get(opts, :exchange, @default_exchange),
      queue: nil,
      connection: nil,
      channel: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, connection, channel, queue} ->
        Process.monitor(connection.pid)
        Logger.info("voice_presence_consumer_connected", queue: queue)
        {:noreply, %{state | connection: connection, channel: channel, queue: queue}}

      {:error, reason} ->
        Logger.warning("voice_presence_consumer_connect_failed",
          reason: Log.reason(reason),
          exchange: state.exchange
        )

        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_presence_consumer_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    Tracing.consumer_span(meta, state.queue, fn ->
      case EventAudit.process(meta.routing_key, payload, fn ->
             process_payload(meta.routing_key, payload)
           end) do
        :ack -> AMQP.Basic.ack(state.channel, meta.delivery_tag)
        _ -> AMQP.Basic.nack(state.channel, meta.delivery_tag, requeue: true)
      end
    end)

    {:noreply, state}
  end

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

  @spec process_payload(String.t(), binary()) :: :ack
  def process_payload(routing_key, payload) do
    with {:ok, event} <- Jason.decode(payload),
         true <- is_map(event),
         true <- routing_key in @routing_keys do
      event = Map.put(event, "event_type", routing_key)
      Contract.check(routing_key, event)

      if routing_key == "voice.private_call" do
        PrivateCall.replicate_event(event)
      else
        VoiceSessionRegistry.replicate_presence(event)
      end
    end

    :ack
  end

  defp connect(state) do
    with {:ok, connection} <- RabbitMQ.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(connection),
         :ok <- AMQP.Exchange.declare(channel, state.exchange, :topic, durable: true),
         {:ok, %{queue: queue}} <- AMQP.Queue.declare(channel, "", exclusive: true),
         :ok <- bind(channel, queue, state.exchange),
         {:ok, _} <- AMQP.Basic.consume(channel, queue) do
      {:ok, connection, channel, queue}
    end
  end

  defp bind(channel, queue, exchange) do
    Enum.reduce_while(@routing_keys, :ok, fn key, :ok ->
      case AMQP.Queue.bind(channel, queue, exchange, routing_key: key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
