defmodule DiscordiaSignaling.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: DiscordiaSignaling.PubSub},
      DiscordiaSignaling.Voice.VoiceSessionRegistry,
      DiscordiaSignalingWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: DiscordiaSignaling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DiscordiaSignalingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
