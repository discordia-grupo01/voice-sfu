defmodule DiscordiaSignaling.Events.MutingConsumer do
  @moduledoc """
  Consumes servers events that affect active voice sessions.

  Mute events update LiveKit publish permissions. Channel access revocations
  remove the listed users from that channel's room, and channel or server
  deletions close the affected rooms.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.RabbitMQ
  alias DiscordiaSignaling.Voice.{LiveKitRoomService, ScreenShare, VoiceSessionRegistry}

  @muted_key "servers.member_muted"
  @unmuted_key "servers.member_unmuted"
  @access_revoked_key "servers.channel_access_revoked"
  @channel_deleted_key "servers.channel_deleted"
  @server_deleted_key "servers.server_deleted"
  @routing_keys [
    @muted_key,
    @unmuted_key,
    @access_revoked_key,
    @channel_deleted_key,
    @server_deleted_key
  ]
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
        Logger.warning("voice_muting_consumer_connect_failed",
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
    case Jason.decode(payload) do
      {:ok, event} -> handle_event(parse_event(routing_key, event))
      {:error, _reason} -> :ack
    end
  end

  defp handle_event({:ok, user_id, can_publish}) do
    with room_name when is_binary(room_name) <- VoiceSessionRegistry.active_room(user_id) do
      [
        room_service().set_publish_permission(room_name, user_id, can_publish)
        | stop_screen_share(room_name, user_id, can_publish)
      ]
      |> ack_unless_failed()
    else
      nil -> :ack
    end
  end

  defp handle_event({:revoke_access, room_name, user_ids}) do
    user_ids
    |> Enum.map(&VoiceSessionRegistry.leave(&1, room_name))
    |> ack_if_all_ok()
  end

  defp handle_event({:close_rooms, room_names}) do
    room_names
    |> Enum.map(&VoiceSessionRegistry.close_room/1)
    |> ack_if_all_ok()
  end

  defp handle_event({:error, _reason}), do: :ack

  defp stop_screen_share(_room_name, _user_id, true), do: []

  defp stop_screen_share(room_name, user_id, false) do
    [room_service().remove_participant(room_name, ScreenShare.identity(user_id))]
  end

  defp ack_unless_failed(results) do
    if Enum.all?(results, &(&1 in [:ok, {:error, :not_found}])), do: :ack, else: :retry
  end

  defp ack_if_all_ok(results) do
    if Enum.all?(results, &(&1 == :ok)), do: :ack, else: :retry
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

  defp parse_event(@access_revoked_key, %{
         "event_id" => event_id,
         "server_id" => server_id,
         "channel_id" => channel_id,
         "user_ids" => [_ | _] = user_ids
       })
       when is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
              is_binary(channel_id) and channel_id != "" do
    if Enum.all?(user_ids, &non_empty_string?/1) do
      {:revoke_access, room_name(channel_id), user_ids}
    else
      {:error, :invalid_event}
    end
  end

  defp parse_event(@channel_deleted_key, %{
         "event_id" => event_id,
         "server_id" => server_id,
         "channel_id" => channel_id
       })
       when is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
              is_binary(channel_id) and channel_id != "" do
    {:close_rooms, [room_name(channel_id)]}
  end

  defp parse_event(@server_deleted_key, %{
         "event_id" => event_id,
         "server_id" => server_id,
         "channel_ids" => channel_ids
       })
       when is_binary(event_id) and event_id != "" and is_binary(server_id) and server_id != "" and
              is_list(channel_ids) do
    if Enum.all?(channel_ids, &non_empty_string?/1) do
      {:close_rooms, Enum.map(channel_ids, &room_name/1)}
    else
      {:error, :invalid_event}
    end
  end

  defp parse_event(_routing_key, _event), do: {:error, :invalid_event}

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp room_name(channel_id), do: "voice:" <> channel_id

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
    Enum.reduce_while(@routing_keys, :ok, fn key, :ok ->
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
