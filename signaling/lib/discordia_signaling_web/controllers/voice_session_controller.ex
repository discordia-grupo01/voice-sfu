defmodule DiscordiaSignalingWeb.VoiceSessionController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
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
      bad_request: {"Falta channel_id", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no puede acceder al canal (voice_forbidden)", "application/json",
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
          with {:ok, authorized_room} <-
                 VoiceAccess.authorize(user_id, channel_id, authorization_header) do
            VoiceSessionRegistry.leave(user_id, authorized_room)
          end
        end

      case result do
        :ok ->
          Plug.Conn.send_resp(conn, 204, "")

        {:error, :not_configured} ->
          conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_not_configured"})

        {:error, :forbidden} ->
          conn |> Plug.Conn.put_status(403) |> json(%{error: "voice_forbidden"})

        {:error, :unavailable} ->
          conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_unavailable"})

        {:error, :not_found} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    catch
      :exit, {:timeout, _} ->
        conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_unavailable"})
    end
  end

  def delete(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "channel_id_required"})
  end
end
