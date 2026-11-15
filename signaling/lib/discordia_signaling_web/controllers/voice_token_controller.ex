defmodule DiscordiaSignalingWeb.VoiceTokenController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.LiveKitToken
  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.Schemas

  tags(["voice"])

  operation(:create,
    summary: "Emite un token de LiveKit para entrar a un canal de voz",
    description:
      "Valida el acceso al canal, emite un token de corta vida para la sala `voice:<channel_id>` y registra al usuario en ella (si estaba en otra sala, lo saca de la anterior).",
    security: [%{"bearerAuth" => []}],
    request_body: {"Canal de voz", "application/json", Schemas.ChannelRequest, required: true},
    responses: [
      ok: {"Token emitido", "application/json", Schemas.VoiceToken},
      bad_request: {"Falta channel_id", "application/json", Schemas.BadRequest},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"El usuario no puede entrar al canal (voice_forbidden)", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"LiveKit o la autorización no están disponibles", "application/json",
         Schemas.ErrorResponse}
    ]
  )

  def create(conn, %{"channel_id" => channel_id}) when is_binary(channel_id) do
    try do
      user_id = conn.assigns.current_user_id
      authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))

      with {:ok, details} <-
             VoiceAccess.authorize_with_details(user_id, channel_id, authorization_header),
           {:ok, token} <-
             LiveKitToken.issue(user_id, details.name, details.room_name, details.can_publish),
           {:ok, _previous_room} <-
             VoiceSessionRegistry.switch(
               user_id,
               details.room_name,
               details.name,
               details.server_id
             ) do
        json(conn, %{
          identity: user_id,
          name: details.name,
          room_name: details.room_name,
          token: token,
          url: LiveKitToken.url()
        })
      else
        {:error, :not_configured} ->
          conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_not_configured"})

        {:error, :forbidden} ->
          conn |> Plug.Conn.put_status(403) |> json(%{error: "voice_forbidden"})

        {:error, :invalid_input} ->
          conn |> Plug.Conn.put_status(400) |> json(%{error: "invalid_channel_id"})

        {:error, :unavailable} ->
          conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_unavailable"})
      end
    catch
      :exit, {:timeout, _} ->
        conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_unavailable"})
    end
  end

  def create(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "channel_id_required"})
  end
end
