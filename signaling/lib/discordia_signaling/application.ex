defmodule DiscordiaSignaling.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: DiscordiaSignaling.PubSub},
        DiscordiaSignaling.Voice.VoicePresencePublisher,
        DiscordiaSignaling.Voice.VoiceSessionRegistry,
        DiscordiaSignaling.Voice.VoicePresenceReconciler,
        presence_consumer(),
        event_consumer(),
        DiscordiaSignalingWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: DiscordiaSignaling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DiscordiaSignalingWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp event_consumer do
    config = Application.get_env(:discordia_signaling, :events, [])
    url = Keyword.get(config, :rabbitmq_url, "")

    if url == "" do
      nil
    else
      {DiscordiaSignaling.Events.MutingConsumer,
       Keyword.put(config, :queue, queue_name(config, "commands"))}
    end
  end

  defp presence_consumer do
    config = Application.get_env(:discordia_signaling, :events, [])
    url = Keyword.get(config, :rabbitmq_url, "")

    if url == "" do
      nil
    else
      {DiscordiaSignaling.Events.PresenceConsumer, config}
    end
  end

  defp queue_name(config, suffix) do
    Keyword.get(config, :queue, "voice.signaling") <>
      "." <> Keyword.get(config, :instance_id, "default") <> "." <> suffix
  end
end
