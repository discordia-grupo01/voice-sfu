defmodule DiscordiaSignaling.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: DiscordiaSignaling.PubSub},
        DiscordiaSignaling.Voice.VoiceSessionRegistry,
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
      {DiscordiaSignaling.Events.MutingConsumer, config}
    end
  end
end
