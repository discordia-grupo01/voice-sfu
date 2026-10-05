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
  end
end
