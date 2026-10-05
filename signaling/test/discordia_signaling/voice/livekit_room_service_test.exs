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

  defp request_with_status(status) do
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
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        body = "{}"

        response =
          "HTTP/1.1 #{status} Status\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    result = LiveKitRoomService.remove_participant("room-1", "user-1")
    assert :ok == Task.await(task, 5_000)
    restore_livekit_config(previous)
    result
  end

  defp restore_livekit_config(nil), do: Application.delete_env(:discordia_signaling, :livekit)

  defp restore_livekit_config(config),
    do: Application.put_env(:discordia_signaling, :livekit, config)
end
