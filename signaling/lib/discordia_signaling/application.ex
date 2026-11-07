defmodule DiscordiaSignaling.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    DiscordiaSignaling.Log.Telemetry.attach()
    DiscordiaSignaling.Tracing.attach()

    Logger.info("service_started",
      version: to_string(Application.spec(:discordia_signaling, :vsn)),
      log_level: Logger.level()
    )

    children =
      [
        {Phoenix.PubSub, name: DiscordiaSignaling.PubSub},
        DiscordiaSignaling.Voice.VoicePresencePublisher,
        DiscordiaSignaling.Voice.VoiceSessionRegistry,
        DiscordiaSignaling.Voice.PrivateCall,
        DiscordiaSignaling.Voice.MembershipCache,
        DiscordiaSignaling.Voice.VoicePresenceReconciler,
        presence_consumer(),
        event_consumer(),
        suspension_versions(),
        suspension_consumer(),
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

  defp suspension_versions do
    if suspension_secret() == "", do: nil, else: DiscordiaSignaling.Events.SuspensionVersions
  end

  defp suspension_consumer do
    config = Application.get_env(:discordia_signaling, :events, [])
    url = Keyword.get(config, :rabbitmq_url, "")

    cond do
      url == "" ->
        nil

      suspension_secret() == "" ->
        Logger.error("voice_suspension_consumer_disabled",
          reason: "empty_admin_events_hmac_secret",
          hint: "admin.user_suspended events will not be consumed"
        )

        nil

      true ->
        {DiscordiaSignaling.Events.SuspensionConsumer,
         config
         |> Keyword.put(:queue, queue_name(config, "suspensions"))
         |> Keyword.put(:hmac_secret, suspension_secret())}
    end
  end

  defp suspension_secret do
    :discordia_signaling
    |> Application.get_env(:events, [])
    |> Keyword.get(:admin_hmac_secret, "")
  end

  defp queue_name(config, suffix) do
    Keyword.get(config, :queue, "voice.signaling") <>
      "." <> Keyword.get(config, :instance_id, "default") <> "." <> suffix
  end
end
