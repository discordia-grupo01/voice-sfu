defmodule DiscordiaSignaling.Integration.VoicePresenceRabbitMQTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.{VoicePresencePublisher, VoiceSessionRegistry}

  @moduletag :integration
  @exchange "discordia.events"

  setup do
    rabbitmq_url = System.get_env("RABBITMQ_URL")

    if is_nil(rabbitmq_url) or rabbitmq_url == "" do
      raise "RABBITMQ_URL must be set when running integration tests"
    else
      previous_events = Application.get_env(:discordia_signaling, :events, [])
      previous_room_service = Application.get_env(:discordia_signaling, :livekit_room_service)
      queue = "voice.integration." <> unique_suffix()

      Application.put_env(:discordia_signaling, :events,
        rabbitmq_url: rabbitmq_url,
        exchange: @exchange
      )

      Application.put_env(
        :discordia_signaling,
        :livekit_room_service,
        DiscordiaSignaling.TestLiveKitRoomService
      )

      VoiceSessionRegistry.reconcile_snapshot([])
      VoiceSessionRegistry.participants()

      on_exit(fn ->
        restore_env(:events, previous_events)
        restore_env(:livekit_room_service, previous_room_service)
      end)

      {:ok, connection} = AMQP.Connection.open(rabbitmq_url)
      {:ok, channel} = AMQP.Channel.open(connection)

      on_exit(fn ->
        AMQP.Connection.close(connection)
      end)

      :ok = AMQP.Exchange.declare(channel, @exchange, :topic, durable: true)
      {:ok, _} = AMQP.Queue.declare(channel, queue, durable: true)
      :ok = AMQP.Queue.bind(channel, queue, @exchange, routing_key: "voice.#")

      {:ok, consumer_pid} =
        DiscordiaSignaling.Events.PresenceConsumer.start_link(
          rabbitmq_url: rabbitmq_url,
          exchange: @exchange,
          queue: queue,
          name: :"presence_consumer_#{unique_suffix()}"
        )

      on_exit(fn -> Process.exit(consumer_pid, :shutdown) end)

      on_exit(fn ->
        AMQP.Queue.delete(channel, queue)
        AMQP.Channel.close(channel)
      end)

      {:ok, []}
    end
  end

  test "publishes presence through RabbitMQ and updates the local registry" do
    user_id = "rabbit-user-" <> unique_suffix()

    joined_event = %{
      "event_id" => "joined-" <> unique_suffix(),
      "event_type" => "voice.participant_joined",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "server_id" => "server-rabbit",
      "room_id" => "room-rabbit",
      "participant_id" => user_id,
      "name" => "Ada"
    }

    assert :ok = VoicePresencePublisher.publish(joined_event)

    wait_until(fn -> VoiceSessionRegistry.active_room(user_id) == "voice:room-rabbit" end)

    left_event = %{
      joined_event
      | "event_id" => "left-" <> unique_suffix(),
        "event_type" => "voice.participant_left",
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert :ok = VoicePresencePublisher.publish(left_event)
    wait_until(fn -> VoiceSessionRegistry.active_room(user_id) == nil end)
    assert VoiceSessionRegistry.participants("server-rabbit") == []
  end

  defp restore_env(:events, []), do: Application.delete_env(:discordia_signaling, :events)

  defp restore_env(:livekit_room_service, nil),
    do: Application.delete_env(:discordia_signaling, :livekit_room_service)

  defp restore_env(key, value), do: Application.put_env(:discordia_signaling, key, value)

  defp unique_suffix do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp wait_until(predicate, attempts \\ 50)

  defp wait_until(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(100)
      wait_until(predicate, attempts - 1)
    end
  end

  defp wait_until(_predicate, 0), do: flunk("timed out waiting for RabbitMQ integration state")
end
