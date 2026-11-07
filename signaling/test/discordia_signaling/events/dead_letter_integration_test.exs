rabbitmq_url = System.get_env("RABBITMQ_URL")

if rabbitmq_url do
  defmodule DiscordiaSignaling.Events.DeadLetterIntegrationTest do
    use ExUnit.Case, async: false

    alias DiscordiaSignaling.Events.DeadLetter

    setup do
      Application.put_env(:discordia_signaling, :event_retry_delay_ms, 5)
      Application.put_env(:discordia_signaling, :event_max_attempts, 3)

      on_exit(fn ->
        Application.delete_env(:discordia_signaling, :event_retry_delay_ms)
        Application.delete_env(:discordia_signaling, :event_max_attempts)
      end)

      {:ok, conn} = AMQP.Connection.open(System.fetch_env!("RABBITMQ_URL"))
      {:ok, chan} = AMQP.Channel.open(conn)
      queue = "voice.signaling.test-#{System.unique_integer([:positive])}"
      {:ok, _info} = AMQP.Queue.declare(chan, queue, durable: true)
      :ok = DeadLetter.declare(chan, queue)

      on_exit(fn ->
        try do
          {:ok, cleanup} = AMQP.Channel.open(conn)
          AMQP.Queue.delete(cleanup, queue)
          AMQP.Queue.delete(cleanup, DeadLetter.queue_for(queue))
          AMQP.Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, conn: conn, chan: chan, queue: queue}
    end

    test "an event that keeps failing ends up in the dead letter queue with its headers", ctx do
      %{conn: conn, chan: chan, queue: queue} = ctx
      payload = Jason.encode!(%{"event_id" => "evt-voice", "server_id" => "srv-1"})
      :ok = AMQP.Basic.publish(chan, "", queue, payload, persistent: true)

      state = %{connection: conn, channel: chan, queue: queue, attempts: %{}}

      final =
        Enum.reduce(1..3, state, fn _attempt, acc ->
          {:ok, ^payload, meta} = AMQP.Basic.get(chan, queue)
          meta = Map.put(meta, :routing_key, "servers.member_muted")
          %{acc | attempts: DeadLetter.finish(:retry, acc, meta, payload)}
        end)

      assert final.attempts == %{}
      assert {:empty, _meta} = AMQP.Basic.get(chan, queue)

      assert {:ok, ^payload, meta} = AMQP.Basic.get(chan, DeadLetter.queue_for(queue), no_ack: true)
      headers = Map.new(meta.headers, fn {name, _type, value} -> {name, value} end)
      assert headers["x-original-queue"] == queue
      assert headers["x-original-routing-key"] == "servers.member_muted"
      assert headers["x-failure-reason"] == "retries_exhausted"
      assert headers["x-attempts"] == 3
      assert headers["x-event-id"] == "evt-voice"
    end
  end
end
