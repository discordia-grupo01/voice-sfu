defmodule DiscordiaSignalingWeb.ApiError do
  @moduledoc """
  Único punto que arma el sobre de error REST del servicio:

      {"error": {"code": "VOICE_FORBIDDEN", "message": "...", "details": {}}}

  Los controllers y plugs devuelven una razón (átomo) y este módulo decide
  status, código y mensaje. Los mensajes nunca incluyen errores internos.
  """

  import Plug.Conn

  @type reason ::
          :invalid_body
          | :unauthorized
          | :forbidden
          | :not_found
          | :method_not_allowed
          | :not_acceptable
          | :payload_too_large
          | :unsupported_media_type
          | :rate_limited
          | :internal_error
          | :bad_gateway
          | :service_unavailable
          | :gateway_timeout
          | :voice_forbidden
          | :voice_unavailable
          | :voice_not_configured
          | :voice_not_in_channel
          | :voice_screen_share_forbidden
          | :voice_call_forbidden
          | :call_not_found
          | :call_already_exists
          | :invalid_call_state

  @spec describe(term()) :: {String.t(), String.t()}
  def describe(:invalid_body), do: {"INVALID_BODY", "El pedido no tiene el formato esperado."}

  def describe(:unauthorized),
    do: {"UNAUTHORIZED", "Falta el token de acceso o no es válido."}

  def describe(:forbidden),
    do: {"FORBIDDEN", "No tenés permiso para realizar esta acción."}

  def describe(:not_found), do: {"NOT_FOUND", "El recurso no existe."}

  def describe(:method_not_allowed),
    do: {"METHOD_NOT_ALLOWED", "El método no está permitido para este recurso."}

  def describe(:not_acceptable),
    do: {"NOT_ACCEPTABLE", "El servicio solo responde en formato JSON."}

  def describe(:payload_too_large),
    do: {"PAYLOAD_TOO_LARGE", "El pedido supera el tamaño máximo permitido."}

  def describe(:unsupported_media_type),
    do: {"UNSUPPORTED_MEDIA_TYPE", "El tipo de contenido no está soportado."}

  def describe(:rate_limited),
    do: {"RATE_LIMITED", "Hiciste demasiados pedidos, intentá de nuevo en un momento."}

  def describe(:internal_error),
    do: {"INTERNAL_ERROR", "Ocurrió un error inesperado, intentá de nuevo más tarde."}

  def describe(:bad_gateway), do: {"BAD_GATEWAY", "Una dependencia respondió con un error."}

  def describe(:service_unavailable),
    do: {"SERVICE_UNAVAILABLE", "El servicio no está disponible, intentá de nuevo en un momento."}

  def describe(:gateway_timeout),
    do: {"GATEWAY_TIMEOUT", "Una dependencia tardó demasiado en responder."}

  def describe(:voice_forbidden),
    do: {"VOICE_FORBIDDEN", "No tenés acceso a este canal de voz."}

  def describe(:voice_unavailable),
    do:
      {"VOICE_UNAVAILABLE",
       "No se pudo completar la operación de voz, intentá de nuevo en un momento."}

  def describe(:voice_not_configured),
    do: {"VOICE_NOT_CONFIGURED", "El servicio de voz no está configurado."}

  def describe(:voice_not_in_channel),
    do: {"VOICE_NOT_IN_CHANNEL", "Tenés que estar conectado a este canal de voz."}

  def describe(:voice_screen_share_forbidden),
    do:
      {"VOICE_SCREEN_SHARE_FORBIDDEN", "No tenés permiso para compartir pantalla en este canal."}

  def describe(:voice_call_forbidden),
    do: {"VOICE_CALL_FORBIDDEN", "No podés realizar esta acción sobre la llamada."}

  def describe(:call_not_found), do: {"CALL_NOT_FOUND", "La llamada no existe."}

  def describe(:call_already_exists),
    do: {"CALL_ALREADY_EXISTS", "Ya hay una llamada en curso entre ambos."}

  def describe(:invalid_call_state),
    do: {"INVALID_CALL_STATE", "La llamada no está en un estado que permita esta acción."}

  # Razón desconocida: nunca debe romper al mapper ni filtrarse al cliente.
  def describe(_other), do: describe(:internal_error)

  @spec http_status(term()) :: pos_integer()
  def http_status(:invalid_body), do: 400
  def http_status(:unauthorized), do: 401
  def http_status(:forbidden), do: 403
  def http_status(:voice_forbidden), do: 403
  def http_status(:voice_screen_share_forbidden), do: 403
  def http_status(:voice_call_forbidden), do: 403
  def http_status(:not_found), do: 404
  def http_status(:call_not_found), do: 404
  def http_status(:method_not_allowed), do: 405
  def http_status(:not_acceptable), do: 406
  def http_status(:voice_not_in_channel), do: 409
  def http_status(:call_already_exists), do: 409
  def http_status(:invalid_call_state), do: 409
  def http_status(:payload_too_large), do: 413
  def http_status(:unsupported_media_type), do: 415
  def http_status(:rate_limited), do: 429
  def http_status(:bad_gateway), do: 502
  def http_status(:service_unavailable), do: 503
  def http_status(:voice_unavailable), do: 503
  def http_status(:voice_not_configured), do: 503
  def http_status(:gateway_timeout), do: 504
  def http_status(_other), do: 500

  @doc "Cuerpo del error. `details` siempre es un mapa (nil pasa a `%{}`)."
  @spec payload(term(), map() | nil) :: map()
  def payload(reason, details \\ %{}) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: normalize_details(details)}}
  end

  @doc "Razón correspondiente a un status HTTP, para los errores que genera el framework."
  @spec reason_for_status(integer()) :: reason()
  def reason_for_status(400), do: :invalid_body
  def reason_for_status(401), do: :unauthorized
  def reason_for_status(403), do: :forbidden
  def reason_for_status(404), do: :not_found
  def reason_for_status(405), do: :method_not_allowed
  def reason_for_status(406), do: :not_acceptable
  def reason_for_status(413), do: :payload_too_large
  def reason_for_status(415), do: :unsupported_media_type
  def reason_for_status(429), do: :rate_limited
  def reason_for_status(502), do: :bad_gateway
  def reason_for_status(503), do: :service_unavailable
  def reason_for_status(504), do: :gateway_timeout
  def reason_for_status(status) when status in 400..499, do: :invalid_body
  def reason_for_status(_status), do: :internal_error

  @doc "Responde con el sobre y corta la cadena de plugs."
  @spec send_error(Plug.Conn.t(), term(), map() | nil) :: Plug.Conn.t()
  def send_error(conn, reason, details \\ %{}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(http_status(reason), Jason.encode!(payload(reason, details)))
    |> halt()
  end

  @doc """
  Traduce el error de una operación de voz (acceso al canal, LiveKit, sala) a su respuesta.
  Cualquier error desconocido, como un `:bad_request` o `:unauthorized` de LiveKit, es una
  dependencia respondiendo mal: 503 `VOICE_UNAVAILABLE`, nunca un 500 sin manejar.
  """
  @spec send_voice_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_voice_error(conn, :not_configured), do: send_error(conn, :voice_not_configured)
  def send_voice_error(conn, :forbidden), do: send_error(conn, :voice_forbidden)
  def send_voice_error(conn, :not_in_room), do: send_error(conn, :voice_not_in_channel)
  def send_voice_error(conn, :cannot_publish), do: send_error(conn, :voice_screen_share_forbidden)

  def send_voice_error(conn, :invalid_input),
    do: send_error(conn, :invalid_body, %{field: "channel_id", reason: "invalid_channel_id"})

  def send_voice_error(conn, _reason), do: send_error(conn, :voice_unavailable)

  defp normalize_details(details) when is_map(details), do: details
  defp normalize_details(_details), do: %{}
end
