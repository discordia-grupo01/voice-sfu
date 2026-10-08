defmodule DiscordiaSignaling.Events.MutingConsumer do
  @moduledoc "Consumes moderation mute events and updates active LiveKit permissions."

  use GenServer
  require Logger

  alias DiscordiaSignaling.Voice.{LiveKitRoomService, VoiceSessionRegistry}

  @muted_key "servers.member_muted"
  @unmuted_key "servers.member_unmuted"
  @default_exchange "discordia.events"
  @default_queue "voice.signaling"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{
      url: Keyword.fetch!(opts, :rabbitmq_url),
      exchange: Keyword.get(opts, :exchange, @default_exchange),
      queue: Keyword.get(opts, :queue, @default_queue),
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
        Logger.info("voice_muting_consumer_connected", queue: state.queue)
        {:noreply, %{state | connection: connection, channel: channel}}

      {:error, reason} ->
        Logger.warning("voice_muting_consumer_connect_failed", reason: inspect(reason))
        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_muting_consumer_connection_down", reason: inspect(reason))
    send(self(), :connect)
    {:noreply, %{state | connection: nil, channel: nil}}
  end

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    result = process_payload(meta.routing_key, payload)
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

  @spec process_payload(String.t(), binary()) :: :ack | :retry
  def process_payload(routing_key, payload) do
    with {:ok, event} <- Jason.decode(payload),
         {:ok, user_id, can_publish} <- parse_event(routing_key, event),
         room_name when is_binary(room_name) <- VoiceSessionRegistry.active_room(user_id) do
      case room_service().set_publish_permission(room_name, user_id, can_publish) do
        :ok -> :ack
        {:error, :not_found} -> :ack
        {:error, _reason} -> :retry
      end
    else
      nil -> :ack
      {:error, _reason} -> :ack
    end
  end

  defp parse_event(@muted_key, %{
         "event_id" => event_id,
         "server_id" => server_id,
         "user_id" => user_id,
         "until_at" => until_at
       })
       when is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
              is_binary(user_id) and user_id != "" and is_binary(until_at) and until_at != "" do
    {:ok, user_id, false}
  end

  defp parse_event(@unmuted_key, %{
         "event_id" => event_id,
         "server_id" => server_id,
         "user_id" => user_id
       })
       when is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
              is_binary(user_id) and user_id != "" do
    {:ok, user_id, true}
  end

  defp parse_event(_routing_key, _event), do: {:error, :invalid_event}

  defp acknowledge(:ack, channel, delivery_tag), do: AMQP.Basic.ack(channel, delivery_tag)

  defp acknowledge(:retry, channel, delivery_tag),
    do: AMQP.Basic.nack(channel, delivery_tag, requeue: true)

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
    Enum.reduce_while([@muted_key, @unmuted_key], :ok, fn key, :ok ->
      case AMQP.Queue.bind(channel, state.queue, state.exchange, routing_key: key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp room_service do
    Application.get_env(:discordia_signaling, :livekit_room_service, LiveKitRoomService)
  end
end
