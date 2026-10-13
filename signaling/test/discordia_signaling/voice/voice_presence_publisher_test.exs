defmodule DiscordiaSignaling.Voice.VoicePresencePublisherTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoicePresencePublisher

  setup do
    previous_events = Application.get_env(:discordia_signaling, :events)
    Application.put_env(:discordia_signaling, :events, [])

    on_exit(fn ->
      if previous_events do
        Application.put_env(:discordia_signaling, :events, previous_events)
      else
        Application.delete_env(:discordia_signaling, :events)
      end
    end)

    :ok
  end

  test "publishes as a no-op when RabbitMQ is not configured" do
    assert :ok = VoicePresencePublisher.publish(%{"event_type" => "voice.test"})
    assert {:ok, state} = VoicePresencePublisher.init([])
    assert state.chan == nil
    assert state.conn == nil
    assert state.size == 0
  end

  test "buffers events while the publisher has no channel" do
    state = state()
    event = %{"event_id" => "event-1", "event_type" => "voice.test"}

    assert {:noreply, next_state} = VoicePresencePublisher.handle_cast({:publish, event}, state)
    assert next_state.size == 1
    assert :queue.to_list(next_state.buffer) == [event]
  end

  test "keeps the buffer bounded by dropping the oldest event" do
    events = Enum.map(1..1_000, &%{"event_id" => Integer.to_string(&1)})
    state = %{state() | buffer: :queue.from_list(events), size: 1_000}
    newest = %{"event_id" => "newest"}

    assert {:noreply, next_state} =
             VoicePresencePublisher.handle_cast({:publish, newest}, state)

    buffered = :queue.to_list(next_state.buffer)
    assert next_state.size == 1_000
    assert hd(buffered) == %{"event_id" => "2"}
    assert List.last(buffered) == newest
  end

  test "ignores connect when a channel already exists" do
    state = %{state() | chan: :channel}
    assert {:noreply, ^state} = VoicePresencePublisher.handle_info(:connect, state)
  end

  test "ignores unrelated messages and exits" do
    state = state()

    assert {:noreply, ^state} = VoicePresencePublisher.handle_info(:unrelated, state)

    assert {:noreply, ^state} =
             VoicePresencePublisher.handle_info({:EXIT, self(), :normal}, state)
  end

  test "backs off when RabbitMQ connection fails" do
    Application.put_env(
      :discordia_signaling,
      :events,
      rabbitmq_url: "amqp://127.0.0.1:1",
      exchange: "discordia.events"
    )

    assert {:noreply, next_state} = VoicePresencePublisher.handle_info(:connect, state())
    assert next_state.chan == nil
    assert next_state.backoff == 2_000
  end

  test "buffers and reconnects after a publish failure" do
    state = %{state() | conn: %{pid: nil}, chan: :fake_channel}
    event = %{"event_type" => "voice.test"}

    assert {:noreply, next_state} = VoicePresencePublisher.handle_cast({:publish, event}, state)
    assert next_state.chan == nil
    assert next_state.conn == nil
    assert next_state.size == 1
    assert :queue.to_list(next_state.buffer) == [event]
    assert next_state.backoff == 2_000
  end

  test "reconnects after the AMQP connection exits" do
    state = %{state() | conn: %{pid: self()}, chan: :fake_channel}

    assert {:noreply, next_state} =
             VoicePresencePublisher.handle_info({:EXIT, self(), :closed}, state)

    assert next_state.conn == nil
    assert next_state.chan == nil
    assert next_state.backoff == 2_000
  end

  test "publish is a no-op when no publisher process is running" do
    Application.put_env(:discordia_signaling, :events, rabbitmq_url: "amqp://unused")
    assert :ok = VoicePresencePublisher.publish(%{"event_type" => "voice.test"})
  end

  test "terminates cleanly without an AMQP connection" do
    assert :ok = VoicePresencePublisher.terminate(:normal, state())
  end

  defp state do
    {:ok, state} = VoicePresencePublisher.init([])
    state
  end
end
