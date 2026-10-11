import Config

config :discordia_signaling, DiscordiaSignalingWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  pubsub_server: DiscordiaSignaling.PubSub,
  secret_key_base: String.duplicate("dev-secret-key-base-", 4),
  render_errors: [formats: [json: DiscordiaSignalingWeb.ErrorJSON]],
  server: true

config :phoenix, :json_library, Jason
