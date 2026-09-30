import Config

config :discordia_signaling, :livekit,
  url: System.get_env("LIVEKIT_URL", "ws://localhost:7880"),
  api_key: System.get_env("LIVEKIT_API_KEY", "devkey"),
  api_secret: System.get_env("LIVEKIT_API_SECRET", "devsecret"),
  token_ttl_seconds: String.to_integer(System.get_env("LIVEKIT_TOKEN_TTL_SECONDS", "3600"))

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT", "4000"))
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :discordia_signaling, DiscordiaSignalingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
