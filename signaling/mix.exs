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
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:jose, "~> 1.11"}
    ]
  end
end
