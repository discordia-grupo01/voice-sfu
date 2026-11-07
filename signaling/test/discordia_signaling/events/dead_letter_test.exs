defmodule DiscordiaSignaling.Events.DeadLetterTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.DeadLetter

  setup do
    on_exit(fn ->
      Application.delete_env(:discordia_signaling, :event_retry_delay_ms)
      Application.delete_env(:discordia_signaling, :event_max_attempts)
    end)
  end

  describe "delay/2" do
    test "doubles on every attempt until it reaches the cap" do
      delays = for attempt <- 1..7, do: DeadLetter.delay(attempt, 0.5)

      assert delays == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]
    end

    test "the jitter moves the delay at most 20% either way" do
      assert DeadLetter.delay(3, 0) == 3_200
      assert DeadLetter.delay(3, 1) == 4_800
    end

    test "starts from the configured base" do
      Application.put_env(:discordia_signaling, :event_retry_delay_ms, 50)

      assert DeadLetter.delay(1, 0.5) == 50
      assert DeadLetter.delay(3, 0.5) == 200
    end

    test "a huge attempt number does not overflow" do
      assert DeadLetter.delay(10_000, 0.5) == 30_000
    end
  end

  describe "max_attempts/0" do
    test "is 5 by default" do
      assert DeadLetter.max_attempts() == 5
    end

    test "can be configured" do
      Application.put_env(:discordia_signaling, :event_max_attempts, 2)

      assert DeadLetter.max_attempts() == 2
    end
  end

  describe "identity/2" do
    test "is the same for the same routing key and body" do
      assert DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.b", "{}")
    end

    test "changes with the routing key or the body" do
      refute DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.c", "{}")
      refute DeadLetter.identity("a.b", "{}") == DeadLetter.identity("a.b", "{\"x\":1}")
    end
  end

  describe "finish/4 with a stand-in channel" do
    defmodule StandInChannel do
      use GenServer

      def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

      @impl true
      def init(test_pid), do: {:ok, test_pid}

      @impl true
      def handle_call({:call, method, _content, _sender}, _from, test_pid) do
        send(test_pid, {:amqp_method, method})
        {:reply, :ok, test_pid}
      end
    end

    setup do
      Application.put_env(:discordia_signaling, :event_retry_delay_ms, 1)
      {:ok, pid} = StandInChannel.start_link(self())
      state = %{channel: %AMQP.Channel{pid: pid}, connection: nil, queue: "q", attempts: %{}}
      {:ok, state: state}
    end

    test "an acknowledged event is confirmed and forgotten", %{state: state} do
      key = DeadLetter.identity("k", "payload")
      state = %{state | attempts: %{key => 3}}

      attempts = DeadLetter.finish(:ack, state, %{delivery_tag: 7, routing_key: "k"}, "payload")

      assert_receive {:amqp_method, {:"basic.ack", 7, false}}
      assert attempts == %{}
    end

    test "a failed event goes back to its queue and its attempts are counted", %{state: state} do
      meta = %{delivery_tag: 8, routing_key: "k"}

      first = DeadLetter.finish(:retry, state, meta, "payload")
      assert_receive {:amqp_method, {:"basic.nack", 8, false, true}}
      assert first == %{DeadLetter.identity("k", "payload") => 1}

      second = DeadLetter.finish(:retry, %{state | attempts: first}, meta, "payload")
      assert_receive {:amqp_method, {:"basic.nack", 8, false, true}}
      assert second == %{DeadLetter.identity("k", "payload") => 2}
    end

    test "the counters are cleared when too many events are being tracked", %{state: state} do
      crowded = Map.new(1..1_024, fn n -> {"other-#{n}", 1} end)

      attempts =
        DeadLetter.finish(
          :retry,
          %{state | attempts: crowded},
          %{delivery_tag: 9, routing_key: "k"},
          "payload"
        )

      assert attempts == %{DeadLetter.identity("k", "payload") => 1}
    end
  end

  test "the dead letter queue of a queue is named after it and the exchange is shared" do
    assert DeadLetter.queue_for("voice.signaling") == "voice.signaling.dlq"
    assert DeadLetter.exchange() == "discordia.dlx"
  end
end
