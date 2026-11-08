import Config

log_level =
  case config_env() do
    :dev -> "debug"
    :test -> "warning"
    :prod -> "info"
  end
  |> then(&System.get_env("LOG_LEVEL", &1))
  |> String.downcase()
  |> case do
    "debug" -> :debug
    "info" -> :info
    level when level in ["warn", "warning"] -> :warning
    "error" -> :error
    other -> raise "LOG_LEVEL must be one of debug, info, warning, error (got: #{inspect(other)})"
  end

config :logger, level: log_level

otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "")

config :opentelemetry,
  text_map_propagators: [:trace_context],
  resource: [service: [name: System.get_env("OTEL_SERVICE_NAME", "voice-sfu")]]

if config_env() == :test do
  config :opentelemetry, traces_exporter: :none, processors: [{:otel_simple_processor, %{}}]

  config :opentelemetry_experimental,
    readers: [
      %{
        module: :otel_metric_reader,
        config: %{
          exporter: {:otel_metric_exporter_pid, {:otel_metric, :discordia_signaling_metric_sink}},
          default_temporality_mapping: %{
            counter: :temporality_delta,
            observable_counter: :temporality_delta,
            histogram: :temporality_delta,
            observable_gauge: :temporality_cumulative,
            updown_counter: :temporality_cumulative,
            observable_updowncounter: :temporality_cumulative
          }
        }
      }
    ]
else
  if otlp_endpoint == "" do
    config :opentelemetry, traces_exporter: :none
    config :opentelemetry_experimental, readers: []
  else
    config :opentelemetry, traces_exporter: :otlp
    config :opentelemetry_exporter, otlp_protocol: :http_protobuf

    config :opentelemetry_experimental,
      readers: [
        %{
          module: :otel_metric_reader,
          config: %{
            exporter: {:otel_exporter_metrics_otlp, %{}},
            export_interval_ms: 60_000,
            default_temporality_mapping: %{
              counter: :temporality_delta,
              observable_counter: :temporality_delta,
              histogram: :temporality_delta,
              observable_gauge: :temporality_cumulative,
              updown_counter: :temporality_cumulative,
              observable_updowncounter: :temporality_cumulative
            }
          }
        }
      ]
  end
end

if config_env() != :test do
  log_ship_url = System.get_env("LOG_SHIP_URL", "")

  log_ship_key =
    case System.get_env("LOG_SHIP_API_KEY", "") do
      "" ->
        System.get_env("OTEL_EXPORTER_OTLP_HEADERS", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.find_value("", fn
          [name, value] ->
            if String.downcase(String.trim(name)) == "api-key", do: String.trim(value)

          _other ->
            nil
        end)

      key ->
        key
    end

  if log_ship_url != "" and log_ship_key != "" do
    config :discordia_signaling, :log_shipper,
      url: log_ship_url,
      api_key: log_ship_key,
      service: System.get_env("OTEL_SERVICE_NAME", "voice-sfu")
  end
end

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
