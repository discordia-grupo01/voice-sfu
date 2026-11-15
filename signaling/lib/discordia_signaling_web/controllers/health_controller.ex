defmodule DiscordiaSignalingWeb.HealthController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignalingWeb.Schemas

  require Logger

  alias DiscordiaSignaling.Readiness

  tags(["ops"])

  operation(:livez,
    summary: "Liveness: el proceso responde, sin tocar ninguna dependencia",
    security: [],
    responses: [ok: {"Servicio vivo", "application/json", Schemas.Health}]
  )

  def livez(conn, _params) do
    json(conn, %{status: "ok"})
  end

  operation(:readyz,
    summary: "Readiness: LiveKit y, según VOICE_AUTHZ_MODE, servers o la réplica local",
    description:
      "Chequea LiveKit (un ListRooms autenticado) y, con VOICE_AUTHZ_MODE=servers_api, que servers responda; con replica, la base de la réplica. No comparte lógica con /livez.",
    security: [],
    responses: [
      ok: {"Dependencias listas", "application/json", Schemas.Health},
      service_unavailable:
        {"Alguna dependencia no responde", "application/json", Schemas.NotReady}
    ]
  )

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
