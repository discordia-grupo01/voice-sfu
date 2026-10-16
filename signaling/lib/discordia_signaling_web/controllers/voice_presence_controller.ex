defmodule DiscordiaSignalingWeb.VoicePresenceController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  @servers_http_options [connect_timeout: 2_000, timeout: 4_000]

  def index(conn, %{"server_id" => server_id}) when is_binary(server_id) and server_id != "" do
    authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    case authorize_server(server_id, authorization_header) do
      :ok ->
        participants =
          server_id
          |> VoiceSessionRegistry.participants()
          |> Enum.group_by(& &1["room_id"])

        json(conn, %{server_id: server_id, channels: channels_response(participants)})

      :forbidden ->
        conn
        |> Plug.Conn.put_status(403)
        |> json(%{error: "voice_forbidden"})

      :unavailable ->
        conn
        |> Plug.Conn.put_status(503)
        |> json(%{error: "voice_unavailable"})
    end
  end

  def index(conn, _params) do
    conn
    |> Plug.Conn.put_status(400)
    |> json(%{error: "server_id_required"})
  end

  defp channels_response(participants) do
    participants
    |> Enum.sort_by(fn {room_id, _} -> room_id end)
    |> Enum.map(fn {room_id, members} ->
      %{channel_id: room_id, participants: Enum.map(members, &Map.drop(&1, ["room_id"]))}
    end)
  end

  defp authorize_server(server_id, authorization_header) do
    mode = Application.get_env(:discordia_signaling, :servers, [])[:authz_mode]

    if mode != "servers_api" do
      :ok
    else
      authorize_server_with_api(server_id, authorization_header)
    end
  end

  defp authorize_server_with_api(server_id, authorization_header)
       when is_binary(authorization_header) and authorization_header != "" do
    base_url = Application.get_env(:discordia_signaling, :servers, [])[:url]
    url = String.to_charlist(base_url <> "/v1/servers/" <> server_id)
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    # Without a timeout, a slow servers API leaves this request hanging until the
    # web BFF gives up (10 s) and the user sees a 502.
    case :httpc.request(:get, {url, headers}, @servers_http_options, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, _body}} -> :ok
      {:ok, {{_, status, _}, _headers, _body}} when status >= 500 -> :unavailable
      {:ok, _response} -> :forbidden
      {:error, _reason} -> :unavailable
    end
  end

  defp authorize_server_with_api(_server_id, _authorization_header), do: :forbidden
end
