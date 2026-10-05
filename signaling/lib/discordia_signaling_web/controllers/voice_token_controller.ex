defmodule DiscordiaSignalingWeb.VoiceTokenController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.LiveKitToken
  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  def create(conn, %{"channel_id" => channel_id}) when is_binary(channel_id) do
    user_id = conn.assigns.current_user_id
    authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    with {:ok, room_name} <- VoiceAccess.authorize(user_id, channel_id, authorization_header),
         {:ok, token} <- LiveKitToken.issue(user_id, room_name),
         {:ok, _previous_room} <- VoiceSessionRegistry.switch(user_id, room_name) do
      json(conn, %{
        identity: user_id,
        room_name: room_name,
        token: token,
        url: livekit_url()
      })
    else
      {:error, :not_configured} ->
        conn
        |> Plug.Conn.put_status(503)
        |> json(%{error: "voice_not_configured"})

      {:error, :forbidden} ->
        conn
        |> Plug.Conn.put_status(403)
        |> json(%{error: "voice_forbidden"})

      {:error, :invalid_input} ->
        conn
        |> Plug.Conn.put_status(400)
        |> json(%{error: "invalid_channel_id"})
    end
  end

  def create(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "channel_id_required"})
  end

  defp livekit_url do
    :discordia_signaling
    |> Application.get_env(:livekit, [])
    |> Keyword.get(:url, "ws://localhost:7880")
  end
end
