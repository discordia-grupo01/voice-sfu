import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT", "4000"))
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :discordia_signaling, DiscordiaSignalingWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
