defmodule DiscordiaSignalingWeb.VoiceSessionController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  def delete(conn, %{"channel_id" => channel_id}) when is_binary(channel_id) do
    user_id = conn.assigns.current_user_id
    authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    with {:ok, room_name} <- VoiceAccess.authorize(user_id, channel_id, authorization_header),
         :ok <- VoiceSessionRegistry.leave(user_id, room_name) do
      Plug.Conn.send_resp(conn, 204, "")
    else
      {:error, :not_configured} ->
        conn
        |> Plug.Conn.put_status(503)
        |> json(%{error: "voice_not_configured"})

      {:error, :forbidden} ->
        conn
        |> Plug.Conn.put_status(403)
        |> json(%{error: "voice_forbidden"})

      {:error, :unavailable} ->
        conn
        |> Plug.Conn.put_status(503)
        |> json(%{error: "voice_unavailable"})

      {:error, :not_found} ->
        Plug.Conn.send_resp(conn, 204, "")
    end
  end

  def delete(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "channel_id_required"})
  end
end
