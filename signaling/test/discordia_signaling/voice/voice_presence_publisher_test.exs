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
