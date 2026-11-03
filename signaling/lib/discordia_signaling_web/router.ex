defmodule DiscordiaSignalingWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Jason
    )

    plug(:accepts, ["json"])
  end

  pipeline :authenticated_api do
    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Jason
    )

    plug(:accepts, ["json"])
    plug(DiscordiaSignalingWeb.AuthPlug)
  end

  scope "/", DiscordiaSignalingWeb do
    pipe_through(:api)

    get("/livez", HealthController, :show)
    get("/readyz", HealthController, :show)
  end

  scope "/api", DiscordiaSignalingWeb do
    pipe_through(:authenticated_api)

    post("/voice/token", VoiceTokenController, :create)
    post("/voice/calls", PrivateCallController, :create)
    post("/voice/calls/:id/accept", PrivateCallController, :accept)
    post("/voice/calls/:id/reject", PrivateCallController, :reject)
    post("/voice/calls/:id/finish", PrivateCallController, :finish)
    post("/voice/screen-token", VoiceScreenTokenController, :create)
    delete("/voice/session", VoiceSessionController, :delete)
    get("/voice/participants", VoicePresenceController, :index)
    post("/voice/socket-ticket", VoiceSocketTicketController, :create)
  end
end
