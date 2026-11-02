defmodule DiscordiaSignalingWeb.VoiceScreenTokenController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.{LiveKitToken, ScreenShare, VoiceAccess, VoiceSessionRegistry}

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
          url: livekit_url()
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

  defp livekit_url do
    :discordia_signaling
    |> Application.get_env(:livekit, [])
    |> Keyword.get(:url, "ws://localhost:7880")
  end
end
