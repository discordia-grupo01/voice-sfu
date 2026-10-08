defmodule DiscordiaSignaling.MixProject do
  use Mix.Project

  def project do
    [
      app: :discordia_signaling,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 70]],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {DiscordiaSignaling.Application, []},
      extra_applications: [:inets, :logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:cowlib, "~> 2.13.0", override: true},
      {:gun, "~> 2.1.0", override: true},
      {:plug_cowboy, "~> 2.7.1"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_pubsub, "~> 2.1.3"},
      {:jason, "~> 1.4.3"},
      {:jose, "~> 1.11.10"},
      {:amqp, "~> 3.3.2"},
      {:ranch, "~> 2.1.0"}
    ]
  end
end
