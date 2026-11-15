defmodule DiscordiaSignalingWeb.VoiceScreenTokenController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  alias DiscordiaSignaling.Voice.{LiveKitToken, ScreenShare, VoiceAccess, VoiceSessionRegistry}
  alias DiscordiaSignalingWeb.Schemas

  tags(["voice"])

  operation(:create,
    summary: "Emite un token de LiveKit para compartir pantalla desde el celular",
    description:
      "Lo usa la app Android, cuya llamada corre en un WebView que no puede capturar la pantalla. Entra a la misma sala una segunda vez con la identidad `<user_id>:screen`, que solo publica pantalla. El usuario ya tiene que estar en la sala del canal y poder hablar.",
    security: [%{"bearerAuth" => []}],
    request_body: {"Canal de voz", "application/json", Schemas.ChannelRequest, required: true},
    responses: [
      ok: {"Token emitido", "application/json", Schemas.ScreenToken},
      bad_request: {"Falta channel_id", "application/json", Schemas.ErrorResponse},
      unauthorized: {"Falta el Bearer o es inválido", "application/json", Schemas.ErrorResponse},
      forbidden:
        {"Sin acceso al canal (voice_forbidden) o un moderador lo silenció (voice_screen_share_forbidden)",
         "application/json", Schemas.ErrorResponse},
      conflict:
        {"El usuario no está en la sala de ese canal (voice_not_in_channel)", "application/json",
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
           :ok <- ensure_in_room(user_id, details.room_name),
           :ok <- ensure_can_publish(details.can_publish),
           {:ok, token} <-
             LiveKitToken.issue_screen_share(user_id, details.name, details.room_name) do
        json(conn, %{
          identity: ScreenShare.identity(user_id),
          room_name: details.room_name,
          token: token,
          url: LiveKitToken.url()
        })
      else
        {:error, :not_in_room} ->
          conn |> Plug.Conn.put_status(409) |> json(%{error: "voice_not_in_channel"})

        {:error, :cannot_publish} ->
          conn |> Plug.Conn.put_status(403) |> json(%{error: "voice_screen_share_forbidden"})

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

  defp ensure_in_room(user_id, room_name) do
    if VoiceSessionRegistry.active_room(user_id) == room_name,
      do: :ok,
      else: {:error, :not_in_room}
  end

  defp ensure_can_publish(true), do: :ok
  defp ensure_can_publish(_can_publish), do: {:error, :cannot_publish}
end
