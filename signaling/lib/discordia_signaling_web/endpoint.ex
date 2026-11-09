defmodule DiscordiaSignalingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :discordia_signaling

  socket("/socket", DiscordiaSignalingWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  socket("/voice/socket", DiscordiaSignalingWeb.UserSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(DiscordiaSignalingWeb.Router)
end
