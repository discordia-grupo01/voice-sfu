defmodule DiscordiaSignalingWeb.VoiceTokenController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.LiveKitToken
  alias DiscordiaSignaling.Voice.VoiceAccess
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

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
