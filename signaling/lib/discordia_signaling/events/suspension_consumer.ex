defmodule DiscordiaSignaling.Events.SuspensionConsumer do
  @moduledoc """
  Removes suspended users from their active voice room.

  Consumes `admin.user_suspended`, verifies its HMAC signature and, when the
  event carries a version newer than the last one handled for that user, takes
  the user out of their room with the same operation used by
  `servers.channel_access_revoked`. Entry to voice is blocked by `servers`
  when the LiveKit token is requested; this consumer only handles users who
  were already connected. `admin.user_reactivated` needs no action here.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.{AdminSignature, RabbitMQ, SuspensionVersions}
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  @suspended_key "admin.user_suspended"
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
        Logger.info("voice_suspension_consumer_connected", queue: state.queue)
        {:noreply, %{state | connection: connection, channel: channel}}

      {:error, reason} ->
        Logger.warning("voice_suspension_consumer_connect_failed",
          reason: inspect(reason),
          queue: state.queue,
          exchange: state.exchange
        )

        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_suspension_consumer_connection_down", reason: inspect(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    result = process_payload(meta.routing_key, payload, state.secret)
    acknowledge(result, state.channel, meta.delivery_tag)
    {:noreply, state}
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
      suspend(parse_event(routing_key, event))
    else
      Logger.warning("voice_suspension_invalid_signature",
        event_id: Map.get(event, "event_id"),
        routing_key: routing_key
      )

      :ack
    end
  end

  defp suspend({:ok, user_id, version}) do
    if SuspensionVersions.newer?(user_id, version) do
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

  defp suspend({:error, _reason}), do: :ack

  defp remove_from_room(user_id) do
    case VoiceSessionRegistry.active_room(user_id) do
      nil -> :ok
      room_name -> VoiceSessionRegistry.leave(user_id, room_name)
    end
  end

  defp parse_event(@suspended_key, %{"user_id" => user_id, "version" => version})
       when is_binary(user_id) and user_id != "" and is_integer(version) do
    {:ok, user_id, version}
  end

  defp parse_event(_routing_key, _event), do: {:error, :invalid_event}

  defp acknowledge(:ack, channel, delivery_tag), do: AMQP.Basic.ack(channel, delivery_tag)

  defp acknowledge(:retry, channel, delivery_tag),
    do: AMQP.Basic.nack(channel, delivery_tag, requeue: true)

  defp connect(state) do
    with {:ok, connection} <- RabbitMQ.open(state.url),
         {:ok, channel} <- AMQP.Channel.open(connection),
         :ok <- AMQP.Exchange.declare(channel, state.exchange, :topic, durable: true),
         {:ok, _} <- AMQP.Queue.declare(channel, state.queue, durable: true),
         :ok <- bind(channel, state),
         {:ok, _} <- AMQP.Basic.consume(channel, state.queue) do
      {:ok, connection, channel}
    end
  end

  defp bind(channel, state) do
    AMQP.Queue.bind(channel, state.queue, state.exchange, routing_key: @suspended_key)
  end
end
