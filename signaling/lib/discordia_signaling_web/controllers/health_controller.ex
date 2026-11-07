defmodule DiscordiaSignalingWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias DiscordiaSignaling.Readiness

  def livez(conn, _params) do
    json(conn, %{status: "ok"})
  end

  def readyz(conn, _params) do
    case Readiness.check() do
      :ok ->
        json(conn, %{status: "ready"})

      {:error, failed} ->
        Logger.warning("readyz_failed", failed: Enum.join(failed, ","))

        conn
        |> put_status(503)
        |> json(%{status: "unavailable", failed: failed})
    end
  end
end
