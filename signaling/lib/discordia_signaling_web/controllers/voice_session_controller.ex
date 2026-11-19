defmodule DiscordiaSignalingWeb.VoiceSessionController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.ApiError
  alias DiscordiaSignalingWeb.Schemas

  tags(["voice"])

  operation(:delete,
    summary: "Sale de un canal de voz",
    description:
      "Saca al usuario autenticado de la sala de LiveKit del canal. Es idempotente: si ya no estaba, responde igual 204.",
    security: [%{"bearerAuth" => []}],
    request_body: {"Canal de voz", "application/json", Schemas.ChannelRequest, required: true},
    responses: [
      no_content: "Salió de la sala, o ya no estaba",
      bad_request: {"Falta channel_id (INVALID_BODY)", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta el Bearer o es inválido (UNAUTHORIZED)", "application/json",
         Schemas.ErrorResponse},
      forbidden:
        {"El usuario no puede acceder al canal (VOICE_FORBIDDEN)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"LiveKit o la autorización no están disponibles", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def delete(conn, %{"channel_id" => channel_id}) when is_binary(channel_id) do
    try do
      user_id = conn.assigns.current_user_id
      authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))
      room_name = "voice:" <> channel_id

      result =
        if is_binary(user_id) and user_id != "" and
             VoiceSessionRegistry.active_room(user_id) == room_name do
          VoiceSessionRegistry.leave(user_id, room_name)
        else
          case VoiceAccess.authorize(user_id, channel_id, authorization_header) do
            {:ok, authorized_room} ->
              VoiceSessionRegistry.leave(user_id, authorized_room)

            {:ok, authorized_room, _name, _can_publish} ->
              VoiceSessionRegistry.leave(user_id, authorized_room)

            {:ok, authorized_room, _name, _can_publish, _server_id} ->
              VoiceSessionRegistry.leave(user_id, authorized_room)

            error ->
              error
          end
        end

      case result do
        :ok ->
          Plug.Conn.send_resp(conn, 204, "")

        {:ok, _} ->
          Plug.Conn.send_resp(conn, 204, "")

        {:error, :not_found} ->
          Plug.Conn.send_resp(conn, 204, "")

        {:error, reason} ->
          ApiError.send_voice_error(conn, reason)
      end
    catch
      :exit, {:timeout, _} ->
        ApiError.send_error(conn, :voice_unavailable)
    end
  end

  def delete(conn, _params) do
    ApiError.send_error(conn, :invalid_body, %{field: "channel_id", reason: "required"})
  end
end
