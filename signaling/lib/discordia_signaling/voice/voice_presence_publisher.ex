defmodule DiscordiaSignaling.Voice.VoicePresencePublisher do
  @moduledoc "Publishes voice presence events to the Discordia RabbitMQ exchange."

  use GenServer
  require Logger

  alias DiscordiaSignaling.Events.RabbitMQ

  @max_buffer 1_000
  @min_backoff 1_000
  @max_backoff 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec publish(map()) :: :ok
  def publish(event) when is_map(event) do
    if broker_url() != nil and Process.whereis(__MODULE__) != nil do
      GenServer.cast(__MODULE__, {:publish, event})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      conn: nil,
      chan: nil,
      buffer: :queue.new(),
      size: 0,
      backoff: @min_backoff
    }

    if broker_url(), do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_cast({:publish, event}, %{chan: nil} = state) do
    {:noreply, enqueue(state, event)}
  end

  def handle_cast({:publish, event}, state) do
    case do_publish(state.chan, event) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("voice_presence_publish_failed", reason: inspect(reason))
        {:noreply, state |> enqueue(event) |> disconnect() |> schedule_connect()}
    end
  end

  @impl true
  def handle_info(:connect, %{chan: nil} = state) do
    case connect() do
      {:ok, conn, chan} ->
        Logger.info("voice_presence_publisher_connected")
        {:noreply, flush(%{state | conn: conn, chan: chan, backoff: @min_backoff})}

      {:error, reason} ->
        Logger.warning("voice_presence_publisher_connect_failed", reason: inspect(reason))
        {:noreply, schedule_connect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{conn: %{pid: pid}} = state) do
    Logger.warning("voice_presence_publisher_disconnected", reason: inspect(reason))
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

  defp do_publish(chan, event) do
    AMQP.Basic.publish(
      chan,
      exchange(),
      event["event_type"],
      Jason.encode!(event),
      persistent: true,
      content_type: "application/json"
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp flush(state) do
    events = :queue.to_list(state.buffer)
    state = %{state | buffer: :queue.new(), size: 0}

    Enum.reduce(events, state, fn event, acc ->
      if acc.chan == nil do
        enqueue(acc, event)
      else
        case do_publish(acc.chan, event) do
          :ok -> acc
          {:error, _reason} -> acc |> enqueue(event) |> disconnect() |> schedule_connect()
        end
      end
    end)
  end

  defp enqueue(%{size: size} = state, event) when size >= @max_buffer do
    {_, buffer} = :queue.out(state.buffer)
    %{state | buffer: :queue.in(event, buffer)}
  end

  defp enqueue(state, event) do
    %{state | buffer: :queue.in(event, state.buffer), size: state.size + 1}
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
