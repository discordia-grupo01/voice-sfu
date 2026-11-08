defmodule DiscordiaSignaling.MixProject do
  use Mix.Project

  def project do
    [
      app: :discordia_signaling,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 70]],
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {DiscordiaSignaling.Application, []},
      extra_applications: [:inets, :logger, :runtime_tools]
    ]
  end

  defp releases do
    [
      discordia_signaling: [
        applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]
      ]
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7.1"},
      {:phoenix, "~> 1.7.14"},
      {:phoenix_pubsub, "~> 2.1.3"},
      {:jason, "~> 1.4.3"},
      {:jose, "~> 1.11.10"},
      {:amqp, "~> 4.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_experimental, "~> 0.6"}
    ]
  end
end
