defmodule DiscordiaSignaling.Voice.VoicePresencePublisher do
  @moduledoc "Publishes voice presence events to the Discordia RabbitMQ exchange."

  require Logger

  @spec publish(map()) :: :ok
  def publish(event) when is_map(event) do
    case Application.get_env(:discordia_signaling, :events, [])[:rabbitmq_url] do
      url when is_binary(url) and url != "" ->
        publish_to_broker(url, event)

      _ ->
        :ok
    end
  end

  defp publish_to_broker(url, event) do
    exchange =
      Application.get_env(:discordia_signaling, :events, [])[:exchange] ||
        "discordia.events"

    routing_key = event["event_type"]

    with {:ok, connection} <- AMQP.Connection.open(url),
         {:ok, channel} <- AMQP.Channel.open(connection),
         :ok <- AMQP.Exchange.declare(channel, exchange, :topic, durable: true),
         :ok <-
           AMQP.Basic.publish(
             channel,
             exchange,
             routing_key,
             Jason.encode!(event),
             persistent: true,
             content_type: "application/json"
           ) do
      AMQP.Connection.close(connection)
      :ok
    else
      {:error, reason} ->
        Logger.error("voice_presence_publish_failed", reason: inspect(reason))
        :ok
    end
  end
end
