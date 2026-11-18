defmodule DiscordiaSignalingWeb.VoiceSocketTicketController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.VoiceSocketTicket
  alias DiscordiaSignalingWeb.ApiError
  alias DiscordiaSignalingWeb.Schemas

  tags(["voice"])

  operation(:create,
    summary: "Emite un ticket para abrir el socket de presencia de voz",
    description:
      "El navegador no puede mandar Authorization al abrir un WebSocket. El cliente pide acá un ticket de 30 segundos y conecta con él.",
    security: [%{"bearerAuth" => []}],
    responses: [
      ok: {"Ticket emitido", "application/json", Schemas.SocketTicket},
      unauthorized:
        {"Falta el Bearer o es inválido (UNAUTHORIZED)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"El servicio no tiene JWT_SECRET (VOICE_NOT_CONFIGURED)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def create(conn, _params) do
    case VoiceSocketTicket.issue(conn.assigns.current_user_id) do
      {:ok, ticket} ->
        json(conn, %{ticket: ticket, expires_in: VoiceSocketTicket.ttl_seconds()})

      {:error, :not_configured} ->
        ApiError.send_error(conn, :voice_not_configured)

      {:error, :invalid_input} ->
        ApiError.send_error(conn, :unauthorized)
    end
  end
end
