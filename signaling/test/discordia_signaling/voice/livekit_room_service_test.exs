defmodule DiscordiaSignaling.Voice.LiveKitRoomServiceTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.LiveKitRoomService

  test "rejects invalid participant data" do
    assert {:error, :invalid_input} = LiveKitRoomService.remove_participant("", "user-1")
    assert {:error, :invalid_input} = LiveKitRoomService.remove_participant("room-1", "")
  end

  test "rejects an unconfigured LiveKit service" do
    previous = Application.get_env(:discordia_signaling, :livekit)
    Application.put_env(:discordia_signaling, :livekit, api_key: "", api_secret: "")

    assert {:error, :not_configured} =
             LiveKitRoomService.remove_participant("room-1", "user-1")

    restore_livekit_config(previous)
  end

  test "maps a missing participant to not_found" do
    assert {:error, :not_found} = request_with_status(404)
  end

  test "returns ok when LiveKit removes the participant" do
    assert :ok = request_with_status(200)
  end

  test "maps an unavailable LiveKit response" do
    assert {:error, :unavailable} = request_with_status(503)
  end

  test "sends RemoveParticipant to the LiveKit room service" do
    {result, request} =
      capture_request(200, fn -> LiveKitRoomService.remove_participant("room-1", "user-1") end)

    assert :ok = result
    assert request =~ "POST /twirp/livekit.RoomService/RemoveParticipant HTTP/1.1"
    assert request_body(request) == %{"room" => "room-1", "identity" => "user-1"}
  end

  test "deletes a room through the LiveKit room service" do
    {result, request} =
      capture_request(200, fn -> LiveKitRoomService.delete_room("voice:channel-1") end)

    assert :ok = result
    assert request =~ "POST /twirp/livekit.RoomService/DeleteRoom HTTP/1.1"
    assert request =~ ~r/authorization: Bearer \S+/i
    assert request_body(request) == %{"room" => "voice:channel-1"}
  end

  test "grants admin rights on the participant's room" do
    {_result, request} =
      capture_request(200, fn -> LiveKitRoomService.remove_participant("room-1", "user-1") end)

    assert %{"roomAdmin" => true, "room" => "room-1"} = video_grant(request)
  end

  test "grants room creation rights to delete a room" do
    {_result, request} =
      capture_request(200, fn -> LiveKitRoomService.delete_room("voice:channel-1") end)

    assert %{"roomAdmin" => true, "roomCreate" => true, "room" => "voice:channel-1"} =
             video_grant(request)
  end

  test "maps a missing room to not_found" do
    {result, _request} =
      capture_request(404, fn -> LiveKitRoomService.delete_room("voice:channel-1") end)

    assert {:error, :not_found} = result
  end

  test "rejects an invalid room name" do
    assert {:error, :invalid_input} = LiveKitRoomService.delete_room("")
    assert {:error, :invalid_input} = LiveKitRoomService.delete_room(nil)
  end

  defp video_grant(request) do
    [_, token] = Regex.run(~r/authorization: Bearer (\S+)/i, request)
    JOSE.JWT.peek_payload(token).fields["video"]
  end

  defp request_with_status(status) do
    {result, _request} =
      capture_request(status, fn -> LiveKitRoomService.remove_participant("room-1", "user-1") end)

    result
  end

  defp capture_request(status, fun) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    previous = Application.get_env(:discordia_signaling, :livekit)

    Application.put_env(:discordia_signaling, :livekit,
      api_key: "test-key",
      api_secret: "test-secret",
      url: "http://localhost:#{port}"
    )

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        request = recv_request(socket, "")
        body = "{}"

        response =
          "HTTP/1.1 #{status} Status\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        request
      end)

    result = fun.()
    request = Task.await(task, 5_000)
    restore_livekit_config(previous)
    {result, request}
  end

  defp recv_request(socket, buffer) do
    with [headers, body] <- String.split(buffer, "\r\n\r\n", parts: 2),
         [_, length] <- Regex.run(~r/content-length: (\d+)/i, headers),
         true <- byte_size(body) >= String.to_integer(length) do
      buffer
    else
      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        recv_request(socket, buffer <> data)
    end
  end

  defp request_body(request) do
    [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    Jason.decode!(body)
  end

  defp restore_livekit_config(nil), do: Application.delete_env(:discordia_signaling, :livekit)

  defp restore_livekit_config(config),
    do: Application.put_env(:discordia_signaling, :livekit, config)
end
