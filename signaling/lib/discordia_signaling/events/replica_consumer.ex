defmodule DiscordiaSignaling.Events.ReplicaConsumer do
  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.{Contract, DeadLetter, RabbitMQ}
  alias DiscordiaSignaling.Log
  alias DiscordiaSignaling.Voice.ReplicaStore

  @routing_keys [
    "servers.role_updated",
    "servers.role_deleted",
    "servers.member_roles_updated",
    "servers.member_left",
    "servers.channel_overrides_updated",
    "servers.owner_updated",
    "servers.channel_created",
    "servers.channel_deleted",
    "servers.server_deleted",
    "servers.member_muted",
    "servers.member_unmuted",
    "users.profile_updated"
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :rabbitmq_url),
      exchange: Keyword.get(opts, :exchange, "discordia.events"),
      queue: Keyword.fetch!(opts, :queue),
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
        Logger.info("voice_replica_consumer_connected", queue: state.queue)
        {:noreply, %{state | connection: connection, channel: channel}}

      {:error, reason} ->
        Logger.warning("voice_replica_consumer_connect_failed", reason: Log.reason(reason))
        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_replica_consumer_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    result = process_payload(meta.routing_key, payload)

    attempts =
      case result do
        :database_retry ->
          Process.sleep(1_000)
          AMQP.Basic.nack(state.channel, meta.delivery_tag, requeue: true)
          state.attempts

        :invalid ->
          DeadLetter.finish(:retry, state, meta, payload)

        :ack ->
          DeadLetter.finish(:ack, state, meta, payload)
      end

    {:noreply, %{state | attempts: attempts}}
  end

  def handle_info({:basic_consume_ok, _}, state), do: {:noreply, state}
  def handle_info({:basic_cancel_ok, _}, state), do: {:noreply, state}
  def handle_info({:basic_cancel, _}, state), do: {:stop, :normal, state}

  @spec process_payload(String.t(), binary()) :: :ack | :invalid | :database_retry
  def process_payload(routing_key, payload) do
    with {:ok, event} <- Jason.decode(payload),
         :ok <- Contract.check(routing_key, event),
         :ok <- validate(routing_key, event) do
      case ReplicaStore.apply_event(routing_key, event) do
        {:ok, :invalid} -> :invalid
        {:ok, _} -> :ack
        :stale -> :ack
        :applied -> :ack
        :invalid -> :invalid
        {:error, :unavailable} -> :database_retry
        {:error, _reason} -> :database_retry
      end
    else
      _ -> :invalid
    end
  end

  defp validate(routing_key, event) do
    if routing_key in @routing_keys and is_binary(event["occurred_at"]) and
         is_binary(event["event_id"]) and event["event_id"] != "" do
      :ok
    else
      {:error, :invalid_event}
    end
  end

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
