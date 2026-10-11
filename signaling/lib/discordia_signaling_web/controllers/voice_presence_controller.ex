defmodule DiscordiaSignalingWeb.VoicePresenceController do
  use Phoenix.Controller, formats: [:json]

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  def index(conn, %{"server_id" => server_id}) when is_binary(server_id) and server_id != "" do
    authorization_header = List.first(Plug.Conn.get_req_header(conn, "authorization"))

    if authorized_server?(server_id, authorization_header) do
      participants =
        server_id
        |> VoiceSessionRegistry.participants()
        |> Enum.group_by(& &1["room_id"])

      json(conn, %{server_id: server_id, channels: channels_response(participants)})
    else
      conn
      |> Plug.Conn.put_status(403)
      |> json(%{error: "voice_forbidden"})
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

  defp authorized_server?(server_id, authorization_header) do
    mode = Application.get_env(:discordia_signaling, :servers, [])[:authz_mode]

    if mode != "servers_api" do
      true
    else
      authorized_server_with_api?(server_id, authorization_header)
    end
  end

  defp authorized_server_with_api?(server_id, authorization_header)
       when is_binary(authorization_header) and authorization_header != "" do
    base_url = Application.get_env(:discordia_signaling, :servers, [])[:url]
    url = String.to_charlist(base_url <> "/v1/servers/" <> server_id)
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, _body}} -> true
      _ -> false
    end
  end

  defp authorized_server_with_api?(_server_id, _authorization_header), do: false
end
