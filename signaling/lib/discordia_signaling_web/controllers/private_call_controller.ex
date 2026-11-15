defmodule DiscordiaSignalingWeb.PrivateCallController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.PrivateCall
  alias DiscordiaSignalingWeb.Schemas

  tags(["calls"])

  operation(:create,
    summary: "Inicia una llamada privada uno a uno",
    description:
      "Valida la conversación directa y que no haya bloqueos en ningún sentido antes de crear la sala privada de LiveKit. La llamada queda sonando 30 segundos.",
    security: [%{"bearerAuth" => []}],
    request_body:
      {"Destinatario y conversación", "application/json", Schemas.CallRequest, required: true},
    responses: [
      created: {"La llamada está sonando", "application/json", Schemas.Call},
      bad_request: {"Datos inválidos", "application/json", Schemas.BadRequest},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"La conversación no admite llamadas o hay un bloqueo (voice_call_forbidden)",
         "application/json", Schemas.ErrorResponse},
      conflict:
        {"Ya hay una llamada entre ambos (call_already_exists)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo validar el contacto (voice_unavailable)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def create(conn, %{"recipient_id" => recipient_id, "conversation_id" => conversation_id}) do
    auth = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    case PrivateCall.start(
           conn.assigns.current_user_id,
           recipient_id,
           conversation_id,
           auth
         ) do
      {:ok, call} -> conn |> put_status(201) |> json(payload(call))
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _), do: error(conn, :invalid_input)

  operation(:accept,
    summary: "Acepta una llamada privada",
    description:
      "Quien acepta recibe sus credenciales de LiveKit; quien llamó recibe las suyas por el evento `private_call_accepted` del socket `voice_user:<user_id>`.",
    security: [%{"bearerAuth" => []}],
    parameters: [id: [in: :path, description: "Identificador de la llamada", type: :string]],
    responses: [
      ok:
        {"Credenciales de LiveKit de la llamada aceptada", "application/json",
         Schemas.AcceptedCall},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no es el destinatario (voice_call_forbidden)", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"La llamada no existe (call_not_found)", "application/json", Schemas.ErrorResponse},
      conflict:
        {"La llamada ya no está sonando (invalid_call_state)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"LiveKit no está configurado (voice_unavailable)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def accept(conn, %{"id" => call_id}) do
    auth = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    case PrivateCall.accept(call_id, conn.assigns.current_user_id, auth) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:screen_token,
    summary: "Emite un token de LiveKit para compartir pantalla en una llamada privada",
    description:
      "Igual que /api/voice/screen-token pero para una llamada privada. Solo lo recibe un participante de una llamada activa.",
    security: [%{"bearerAuth" => []}],
    parameters: [id: [in: :path, description: "Identificador de la llamada", type: :string]],
    responses: [
      ok: {"Token emitido", "application/json", Schemas.ScreenToken},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no participa de la llamada (voice_call_forbidden)", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"La llamada no existe (call_not_found)", "application/json", Schemas.ErrorResponse},
      conflict:
        {"La llamada no está activa (invalid_call_state)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"LiveKit no está configurado (voice_unavailable)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def screen_token(conn, %{"id" => call_id}) do
    case PrivateCall.screen_share_token(call_id, conn.assigns.current_user_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:reject,
    summary: "Rechaza o cancela una llamada que está sonando",
    description:
      "El destinatario la rechaza, o quien llamó la cancela antes de que la atiendan. Ambos reciben `private_call_rejected`.",
    security: [%{"bearerAuth" => []}],
    parameters: [id: [in: :path, description: "Identificador de la llamada", type: :string]],
    responses: [
      no_content: "Llamada rechazada",
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no participa de la llamada (voice_call_forbidden)", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"La llamada no existe (call_not_found)", "application/json", Schemas.ErrorResponse},
      conflict:
        {"La llamada ya no está sonando (invalid_call_state)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def reject(conn, %{"id" => call_id}), do: action(conn, call_id, :reject)

  operation(:finish,
    summary: "Termina una llamada activa",
    description: "Ambos participantes reciben `private_call_ended` con motivo `hangup`.",
    security: [%{"bearerAuth" => []}],
    parameters: [id: [in: :path, description: "Identificador de la llamada", type: :string]],
    responses: [
      no_content: "Llamada terminada",
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no participa de la llamada (voice_call_forbidden)", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"La llamada no existe (call_not_found)", "application/json", Schemas.ErrorResponse},
      conflict:
        {"La llamada no está activa (invalid_call_state)", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def finish(conn, %{"id" => call_id}), do: action(conn, call_id, :finish)

  defp action(conn, call_id, :reject) do
    case PrivateCall.reject(call_id, conn.assigns.current_user_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp action(conn, call_id, :finish) do
    case PrivateCall.finish(call_id, conn.assigns.current_user_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> error(conn, reason)
    end
  end

  defp payload(call) when is_map(call) do
    %{
      "call_id" => call.id,
      "conversation_id" => call.conversation_id,
      "caller_id" => call.caller_id,
      "recipient_id" => call.recipient_id,
      "room_name" => call.room_name,
      "status" => Atom.to_string(call.status)
    }
  end

  defp error(conn, :invalid_input), do: conn |> put_status(400) |> json(%{error: "invalid_input"})

  defp error(conn, :forbidden),
    do: conn |> put_status(403) |> json(%{error: "voice_call_forbidden"})

  defp error(conn, :call_not_found),
    do: conn |> put_status(404) |> json(%{error: "call_not_found"})

  defp error(conn, :call_already_exists),
    do: conn |> put_status(409) |> json(%{error: "call_already_exists"})

  defp error(conn, :invalid_call_state),
    do: conn |> put_status(409) |> json(%{error: "invalid_call_state"})

  defp error(conn, :not_configured),
    do: conn |> put_status(503) |> json(%{error: "voice_unavailable"})

  defp error(conn, _reason), do: conn |> put_status(403) |> json(%{error: "voice_call_forbidden"})
end
