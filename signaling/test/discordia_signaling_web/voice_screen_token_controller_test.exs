defmodule DiscordiaSignalingWeb.VoiceScreenTokenControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoiceScreenTokenController

  @channel_id "550e8400-e29b-41d4-a716-446655440000"
  @room "voice:550e8400-e29b-41d4-a716-446655440000"

  setup do
    TestHelpers.put_livekit_config()
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_servers = Application.get_env(:discordia_signaling, :servers)
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    on_exit(fn ->
      VoiceSessionRegistry.leave("screen-user", @room)

      if previous_mode,
        do: System.put_env("VOICE_AUTHZ_MODE", previous_mode),
        else: System.delete_env("VOICE_AUTHZ_MODE")

      if previous_servers do
        Application.put_env(:discordia_signaling, :servers, previous_servers)
      else
        Application.delete_env(:discordia_signaling, :servers)
      end

      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end
    end)

    :ok
  end

  test "issues a companion token for a user already in the room" do
    assert {:ok, _previous} = VoiceSessionRegistry.switch("screen-user", @room)

    conn = request("screen-user") |> VoiceScreenTokenController.create(body())

    assert conn.status == 200
    response = Jason.decode!(conn.resp_body)
    assert response["identity"] == "screen-user:screen"
    assert response["room_name"] == @room
    assert response["url"] == "ws://test-livekit:7880"

    assert JOSE.JWT.peek_payload(response["token"]).fields["video"]["canPublishSources"] ==
             ["screen_share", "screen_share_audio"]
  end

  test "does not replace the user's voice session" do
    assert {:ok, _previous} = VoiceSessionRegistry.switch("screen-user", @room)

    assert request("screen-user") |> VoiceScreenTokenController.create(body()) |> Map.get(:status) ==
             200

    assert VoiceSessionRegistry.active_room("screen-user") == @room
    refute_received {:removed_participant, @room, "screen-user"}
  end

  test "rejects a user who is not in that channel" do
    conn = request("screen-user") |> VoiceScreenTokenController.create(body())

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "voice_not_in_channel"}
  end

  test "rejects a member muted by a moderator" do
    assert {:ok, _previous} = VoiceSessionRegistry.switch("screen-user", @room)
    server = serve_voice_access(~s({"allowed":true,"muted":true}))

    conn =
      request("screen-user")
      |> Plug.Conn.put_req_header("authorization", "Bearer token")
      |> VoiceScreenTokenController.create(body())

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "voice_screen_share_forbidden"}
    assert :ok == Task.await(server, 5_000)
  end

  test "rejects an invalid identity" do
    conn = request(nil) |> VoiceScreenTokenController.create(body())

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "voice_forbidden"}
  end

  test "rejects a request without a channel id" do
    conn = request("screen-user") |> VoiceScreenTokenController.create(%{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "channel_id_required"}
  end

  defp request(user_id) do
    Plug.Conn.assign(conn(:post, "/api/voice/screen-token"), :current_user_id, user_id)
  end

  defp body, do: %{"channel_id" => @channel_id}

  defp serve_voice_access(response_body) do
    System.put_env("VOICE_AUTHZ_MODE", "servers_api")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    Application.put_env(:discordia_signaling, :servers, url: "http://localhost:#{port}")

    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " <>
          Integer.to_string(byte_size(response_body)) <>
          "\r\nConnection: close\r\n\r\n" <> response_body

      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen_socket)
    end)
  end
end
