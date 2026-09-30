defmodule DiscordiaSignalingWeb.VoiceTokenController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.LiveKitToken
  alias DiscordiaSignaling.Voice.VoiceAccess

  def create(conn, %{"room_name" => room_name}) when is_binary(room_name) do
    user_id = conn.assigns.current_user_id

    with :ok <- VoiceAccess.authorize(user_id, room_name),
         {:ok, token} <- LiveKitToken.issue(user_id, room_name) do
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
        |> json(%{error: "invalid_room_name"})
    end
  end

  def create(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "room_name_required"})
  end

  defp livekit_url do
    :discordia_signaling
    |> Application.get_env(:livekit, [])
    |> Keyword.get(:url, "ws://localhost:7880")
  end
end
