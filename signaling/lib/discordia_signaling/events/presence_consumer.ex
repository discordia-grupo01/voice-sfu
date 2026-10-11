defmodule DiscordiaSignaling.Events.PresenceConsumer do
  @moduledoc """
  Replicates voice presence events from RabbitMQ into this signaling instance.

  Each signaling instance has its own queue, so every instance receives every
  presence event instead of RabbitMQ load-balancing it between replicas.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  @routing_keys ["voice.participant_joined", "voice.participant_left"]
  @default_exchange "discordia.events"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :rabbitmq_url),
      exchange: Keyword.get(opts, :exchange, @default_exchange),
      queue: Keyword.fetch!(opts, :queue),
      connection: nil,
      channel: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, connection, channel} ->
        Process.monitor(connection.pid)
        Logger.info("voice_presence_consumer_connected", queue: state.queue)
        {:noreply, %{state | connection: connection, channel: channel}}

      {:error, reason} ->
        Logger.warning("voice_presence_consumer_connect_failed", reason: inspect(reason))
        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_presence_consumer_connection_down", reason: inspect(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    process_payload(meta.routing_key, payload)
    AMQP.Basic.ack(state.channel, meta.delivery_tag)
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
      VoiceSessionRegistry.replicate_presence(Map.put(event, "event_type", routing_key))
    end

    :ack
  end

  defp connect(state) do
    with {:ok, connection} <- AMQP.Connection.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(connection),
         :ok <- AMQP.Exchange.declare(channel, state.exchange, :topic, durable: true),
         {:ok, _} <- AMQP.Queue.declare(channel, state.queue, durable: true),
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
