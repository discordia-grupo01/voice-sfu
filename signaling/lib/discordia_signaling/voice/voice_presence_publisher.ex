defmodule DiscordiaSignaling.Voice.VoicePresencePublisher do
  @moduledoc "Publishes voice presence events to the Discordia RabbitMQ exchange."

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.{Contract, RabbitMQ}
  alias DiscordiaSignaling.Log

  @min_backoff 1_000
  @max_backoff 30_000
  @drain_interval 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec publish(map()) :: :ok
  def publish(event) when is_map(event) do
    if broker_url() != nil do
      case enqueue_outbox(event) do
        :ok ->
          if Process.whereis(__MODULE__) != nil, do: send(__MODULE__, :drain)

        {:error, reason} ->
          Logger.error("voice_presence_outbox_enqueue_failed", reason: Log.reason(reason))
      end
    end

    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      conn: nil,
      chan: nil,
      backoff: @min_backoff
    }

    if broker_url(), do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{chan: nil} = state) do
    case connect() do
      {:ok, conn, chan} ->
        Logger.info("voice_presence_publisher_connected")
        send(self(), :drain)
        {:noreply, %{state | conn: conn, chan: chan, backoff: @min_backoff}}

      {:error, reason} ->
        Logger.warning("voice_presence_publisher_connect_failed", reason: Log.reason(reason))
        {:noreply, schedule_connect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:drain, %{chan: nil} = state), do: {:noreply, state}

  def handle_info(:drain, state) do
    case event_store().pending_outbox(100) do
      {:ok, events} ->
        next_state =
          Enum.reduce_while(events, state, fn event, acc ->
            case do_publish(acc.chan, event.payload) do
              :ok ->
                case event_store().mark_outbox_published(event.event_id) do
                  :ok -> {:cont, acc}
                  {:error, reason} -> {:halt, disconnect_and_retry(acc, reason)}
                end

              {:error, reason} ->
                {:halt, disconnect_and_retry(acc, reason)}
            end
          end)

        if next_state.chan != nil, do: Process.send_after(self(), :drain, @drain_interval)
        {:noreply, next_state}

      {:error, reason} ->
        Logger.warning("voice_presence_outbox_read_failed", reason: Log.reason(reason))
        {:noreply, schedule_connect(state)}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{conn: %{pid: pid}} = state) do
    Logger.warning("voice_presence_publisher_disconnected", reason: Log.reason(reason))
    {:noreply, state |> Map.merge(%{conn: nil, chan: nil}) |> schedule_connect()}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    disconnect(state)
    :ok
  end

  defp connect do
    url = broker_url()

    with {:ok, conn} <- RabbitMQ.open(url) do
      with {:ok, chan} <- AMQP.Channel.open(conn),
           :ok <- AMQP.Exchange.declare(chan, exchange(), :topic, durable: true) do
        {:ok, conn, chan}
      else
        error ->
          safe_close(conn)
          normalize_error(error)
      end
    else
      error -> normalize_error(error)
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_error({:error, _} = error), do: error
  defp normalize_error(other), do: {:error, other}

  defp do_publish(chan, payload) do
    {:ok, event} = Jason.decode(payload)
    Contract.check(event["event_type"], event)

    AMQP.Basic.publish(
      chan,
      exchange(),
      event["event_type"],
      payload,
      persistent: true,
      content_type: "application/json"
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp disconnect(%{conn: nil} = state), do: state

  defp disconnect(%{conn: conn} = state) do
    safe_close(conn)
    %{state | conn: nil, chan: nil}
  end

  defp safe_close(conn) do
    AMQP.Connection.close(conn)
  catch
    _, _ -> :ok
  end

  defp schedule_connect(state) do
    Process.send_after(self(), :connect, state.backoff)
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp disconnect_and_retry(state, reason) do
    Logger.warning("voice_presence_publish_failed", reason: Log.reason(reason))
    state |> disconnect() |> schedule_connect()
  end

  defp event_store do
    Application.get_env(
      :discordia_signaling,
      :voice_event_store,
      DiscordiaSignaling.Voice.ReplicaStore
    )
  end

  defp enqueue_outbox(event) do
    event_store().enqueue_outbox(event)
  catch
    :exit, reason -> {:error, reason}
  end

  defp broker_url do
    case Application.get_env(:discordia_signaling, :events, [])[:rabbitmq_url] do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp exchange do
    Application.get_env(:discordia_signaling, :events, [])[:exchange] || "discordia.events"
  end
end
