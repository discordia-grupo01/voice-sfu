defmodule DiscordiaSignaling.Integration.VoiceSuspensionRabbitMQTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.{SuspensionConsumer, SuspensionVersions}
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  @moduletag :integration
  @exchange "discordia.events"
  @key "admin.user_suspended"
  @server_key "admin.server_suspended"
  @server_reactivated_key "admin.server_reactivated"
  @secret "integration-secret"

  setup do
    rabbitmq_url = System.get_env("RABBITMQ_URL")

    if is_nil(rabbitmq_url) or rabbitmq_url == "" do
      raise "RABBITMQ_URL must be set when running integration tests"
    end

    previous_room_service = Application.get_env(:discordia_signaling, :livekit_room_service)

    Application.put_env(
      :discordia_signaling,
      :livekit_room_service,
      DiscordiaSignaling.TestLiveKitRoomService
    )

    on_exit(fn ->
      if previous_room_service do
        Application.put_env(:discordia_signaling, :livekit_room_service, previous_room_service)
      else
        Application.delete_env(:discordia_signaling, :livekit_room_service)
      end
    end)

    start_supervised!(SuspensionVersions)

    queue = "voice.integration.suspensions." <> unique_suffix()

    {:ok, connection} = AMQP.Connection.open(rabbitmq_url)
    {:ok, channel} = AMQP.Channel.open(connection)
    :ok = AMQP.Exchange.declare(channel, @exchange, :topic, durable: true)
    {:ok, _} = AMQP.Queue.declare(channel, queue, durable: true)
    for key <- [@key, @server_key, @server_reactivated_key] do
      :ok = AMQP.Queue.bind(channel, queue, @exchange, routing_key: key)
    end

    on_exit(fn ->
      AMQP.Queue.delete(channel, queue)
      AMQP.Connection.close(connection)
    end)

    start_supervised!(
      {SuspensionConsumer,
       rabbitmq_url: rabbitmq_url,
       exchange: @exchange,
       queue: queue,
       hmac_secret: @secret,
       name: :"suspension_consumer_#{unique_suffix()}"}
    )

    wait_until(fn -> consuming?(channel, queue) end)

    {:ok, channel: channel}
  end

  test "removes a connected user on a signed event and ignores a forged one", %{channel: channel} do
    user_id = "suspended-" <> unique_suffix()
    join(user_id)

    forged = event(user_id, 1, "wrong-secret")
    :ok = AMQP.Basic.publish(channel, @exchange, @key, Jason.encode!(forged))
    Process.sleep(500)
    assert VoiceSessionRegistry.active_room(user_id) == "voice:room-suspension"

    :ok = AMQP.Basic.publish(channel, @exchange, @key, Jason.encode!(event(user_id, 1, @secret)))
    wait_until(fn -> VoiceSessionRegistry.active_room(user_id) == nil end)
  end

  test "closes the rooms of a suspended server on a signed event and ignores a forged one",
       %{channel: channel} do
    server_id = "server-" <> unique_suffix()
    other_server_id = "server-" <> unique_suffix()
    users = for n <- 1..3, do: "member-#{n}-" <> unique_suffix()
    bystander = "bystander-" <> unique_suffix()

    join_server(Enum.at(users, 0), "room-a", server_id)
    join_server(Enum.at(users, 1), "room-a", server_id)
    join_server(Enum.at(users, 2), "room-b", server_id)
    join_server(bystander, "room-c", other_server_id)

    forged = server_event(@server_key, server_id, 1, "wrong-secret")
    :ok = AMQP.Basic.publish(channel, @exchange, @server_key, Jason.encode!(forged))
    # A signed suspension of another routing key can't pass as this one.
    reactivation = server_event(@server_reactivated_key, server_id, 2, @secret)
    :ok = AMQP.Basic.publish(channel, @exchange, @server_key, Jason.encode!(reactivation))
    Process.sleep(500)
    assert Enum.all?(users, &(VoiceSessionRegistry.active_room(&1) != nil))

    valid = server_event(@server_key, server_id, 3, @secret)
    :ok = AMQP.Basic.publish(channel, @exchange, @server_key, Jason.encode!(valid))

    wait_until(fn -> Enum.all?(users, &(VoiceSessionRegistry.active_room(&1) == nil)) end)
    assert VoiceSessionRegistry.active_room(bystander) == "voice:room-c"
  end

  test "an old suspension arriving after the reactivation expels nobody", %{channel: channel} do
    server_id = "server-" <> unique_suffix()
    user_id = "member-" <> unique_suffix()
    probe_user = "probe-" <> unique_suffix()
    join_server(user_id, "room-late", server_id)
    join_server(probe_user, "room-probe", "server-" <> unique_suffix())

    reactivated = server_event(@server_reactivated_key, server_id, 2, @secret)
    :ok = AMQP.Basic.publish(channel, @exchange, @server_reactivated_key, Jason.encode!(reactivated))
    old = server_event(@server_key, server_id, 1, @secret)
    :ok = AMQP.Basic.publish(channel, @exchange, @server_key, Jason.encode!(old))

    # The probe goes through the same queue and consumer, after the two above.
    :ok = AMQP.Basic.publish(channel, @exchange, @key, Jason.encode!(event(probe_user, 1, @secret)))
    wait_until(fn -> VoiceSessionRegistry.active_room(probe_user) == nil end)

    assert VoiceSessionRegistry.active_room(user_id) == "voice:room-late"
  end

  defp server_event(routing_key, server_id, version, secret) do
    event = %{
      "event_id" => "evt-" <> unique_suffix(),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "server_id" => server_id,
      "version" => version
    }

    text =
      Enum.join(
        [routing_key, event["event_id"], server_id, Integer.to_string(version), event["occurred_at"]],
        "\n"
      )

    signature = :crypto.mac(:hmac, :sha256, secret, text) |> Base.encode16(case: :lower)
    Map.put(event, "signature", signature)
  end

  # Registers someone as connected to a room of a server. The reconciler is not
  # running in tests, so nothing drops them from the registry until the consumer does.
  defp join_server(user_id, room_id, server_id) do
    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_joined",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "server_id" => server_id,
      "room_id" => room_id,
      "participant_id" => user_id,
      "name" => "Ada"
    })
  end

  defp event(user_id, version, secret) do
    event = %{
      "event_id" => "evt-" <> unique_suffix(),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "user_id" => user_id,
      "version" => version
    }

    text =
      Enum.join(
        [@key, event["event_id"], user_id, Integer.to_string(version), event["occurred_at"]],
        "\n"
      )

    signature = :crypto.mac(:hmac, :sha256, secret, text) |> Base.encode16(case: :lower)
    Map.put(event, "signature", signature)
  end

  # The app's reconciler may still be retrying against LiveKit when the test starts;
  # report the user as connected so a reconciliation does not drop them from the registry.
  defp join(user_id) do
    Application.put_env(
      :discordia_signaling,
      :test_active_participants,
      {:ok,
       [
         %{
           identity: user_id,
           room_name: "voice:room-suspension",
           name: "Ada",
           server_id: "server-suspension"
         }
       ]}
    )

    on_exit(fn -> Application.delete_env(:discordia_signaling, :test_active_participants) end)

    VoiceSessionRegistry.replicate_presence(%{
      "event_type" => "voice.participant_joined",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "server_id" => "server-suspension",
      "room_id" => "room-suspension",
      "participant_id" => user_id,
      "name" => "Ada"
    })
  end

  defp consuming?(channel, queue) do
    match?({:ok, %{consumer_count: count}} when count > 0, AMQP.Queue.status(channel, queue))
  end

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
