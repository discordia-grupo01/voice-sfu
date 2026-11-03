import Config

allowed_origins =
  System.get_env(
    "PHOENIX_CHECK_ORIGINS",
    "http://localhost:3000,http://127.0.0.1:3000"
  )
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

config :discordia_signaling, DiscordiaSignalingWeb.Endpoint, check_origin: allowed_origins

config :discordia_signaling, :livekit,
  url: System.get_env("LIVEKIT_URL", "ws://localhost:7880"),
  api_key: System.get_env("LIVEKIT_API_KEY", "devkey"),
  api_secret: System.get_env("LIVEKIT_API_SECRET", "devsecret"),
  token_ttl_seconds: String.to_integer(System.get_env("LIVEKIT_TOKEN_TTL_SECONDS", "3600"))

config :discordia_signaling, :servers,
  url: System.get_env("SERVERS_URL", "http://servers:8080"),
  authz_mode: System.get_env("VOICE_AUTHZ_MODE", "deny")

config :discordia_signaling, :messaging,
  url: System.get_env("MESSAGING_URL", "http://messaging:4000")

config :discordia_signaling, :events,
  rabbitmq_url: System.get_env("RABBITMQ_URL", ""),
  exchange: System.get_env("EVENTS_EXCHANGE", "discordia.events"),
  admin_hmac_secret: System.get_env("ADMIN_EVENTS_HMAC_SECRET", ""),
  queue: System.get_env("VOICE_EVENTS_QUEUE", "voice.signaling"),
  instance_id:
    System.get_env("VOICE_INSTANCE_ID") ||
      System.get_env("FLY_ALLOC_ID") ||
      System.get_env("HOSTNAME") ||
      "default"

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT", "4000"))
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :discordia_signaling, DiscordiaSignalingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
