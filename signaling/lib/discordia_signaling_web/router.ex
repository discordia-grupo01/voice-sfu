defmodule DiscordiaSignalingWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", DiscordiaSignalingWeb do
    pipe_through :api

    get "/livez", HealthController, :show
    get "/readyz", HealthController, :show
  end
end
