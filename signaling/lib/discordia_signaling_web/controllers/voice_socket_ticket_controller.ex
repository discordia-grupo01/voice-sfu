defmodule DiscordiaSignalingWeb.VoiceSocketTicketController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.VoiceSocketTicket

  def create(conn, _params) do
    case VoiceSocketTicket.issue(conn.assigns.current_user_id) do
      {:ok, ticket} ->
        json(conn, %{ticket: ticket, expires_in: VoiceSocketTicket.ttl_seconds()})

      {:error, :not_configured} ->
        conn |> Plug.Conn.put_status(503) |> json(%{error: "voice_not_configured"})

      {:error, :invalid_input} ->
        conn |> Plug.Conn.put_status(401) |> json(%{error: "unauthorized"})
    end
  end
end
