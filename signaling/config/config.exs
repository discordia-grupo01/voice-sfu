import Config

config :discordia_signaling, DiscordiaSignalingWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  pubsub_server: DiscordiaSignaling.PubSub,
  secret_key_base: String.duplicate("dev-secret-key-base-", 4),
  render_errors: [formats: [json: DiscordiaSignalingWeb.ErrorJSON]],
  server: true

config :phoenix, :json_library, Jason

config :logger, :console,
  format: {DiscordiaSignaling.Log.JSONFormatter, :format},
  metadata: [
    :request_id,
    :user_id,
    :server_id,
    :channel_id,
    :topic,
    :event,
    :result,
    :transport,
    :method,
    :route,
    :status,
    :duration_ms,
    :routing_key,
    :event_id,
    :exchange,
    :queue,
    :attempt,
    :attempts,
    :retry_in_ms,
    :rooms_closed,
    :reason,
    :failed,
    :hint,
    :version,
    :log_level
  ]

config :phoenix, :logger, false

config :phoenix,
       :filter_parameters,
       {:keep, ["id", "channel_id", "call_id", "vsn"]}
