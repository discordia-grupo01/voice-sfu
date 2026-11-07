defmodule DiscordiaSignalingWeb.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.Router

  setup do
    previous_secret = System.get_env("JWT_SECRET")
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_servers = Application.get_env(:discordia_signaling, :servers)
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    TestHelpers.put_livekit_config()

    System.put_env("JWT_SECRET", "jwt-secret")
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("JWT_SECRET", previous_secret),
        else: System.delete_env("JWT_SECRET")

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

  test "livez returns ok" do
    conn = Router.call(conn(:get, "/livez"), Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "issues a LiveKit token for an authenticated request" do
    channel_id = "550e8400-e29b-41d4-a716-446655440000"

    conn =
      conn(:post, "/api/voice/token", Jason.encode!(%{"channel_id" => channel_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-user-id", "user-42")
      |> Router.call(Router.init([]))

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["identity"] == "user-42"
    assert body["room_name"] == "voice:" <> channel_id
    assert body["url"] == "ws://test-livekit:7880"
    assert is_binary(body["token"])
  end

  test "rejects unauthenticated requests" do
    channel_id = "550e8400-e29b-41d4-a716-446655440000"

    conn =
      conn(:post, "/api/voice/token", Jason.encode!(%{"channel_id" => channel_id}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "accepts the servers_api flow when the authorization service approves the channel" do
    channel_id = "550e8400-e29b-41d4-a716-446655440000"
    System.put_env("VOICE_AUTHZ_MODE", "servers_api")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    Application.put_env(:discordia_signaling, :servers, url: "http://localhost:#{port}")

    server_task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0)
        assert String.contains?(request, "/v1/channels/" <> channel_id <> "/voice-access")

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 29\r\nConnection: close\r\n\r\n{\"allowed\":true,\"name\":\"Ada\"}"

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    token = TestHelpers.signed_access_token(%{"sub" => "user-77"})

    conn =
      conn(:post, "/api/voice/token", Jason.encode!(%{"channel_id" => channel_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["identity"] == "user-77"
    assert body["name"] == "Ada"
    assert body["room_name"] == "voice:" <> channel_id
    assert is_binary(body["token"])

    assert :ok == Task.await(server_task, 5_000)
  end

  test "falls back to the identity when servers_api omits the profile name" do
    channel_id = "550e8400-e29b-41d4-a716-446655440000"
    System.put_env("VOICE_AUTHZ_MODE", "servers_api")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    Application.put_env(:discordia_signaling, :servers, url: "http://localhost:#{port}")

    server_task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0)

        response =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"allowed\":true}"

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    token = TestHelpers.signed_access_token(%{"sub" => "user-77"})

    conn =
      conn(:post, "/api/voice/token", Jason.encode!(%{"channel_id" => channel_id}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["identity"] == "user-77"
    assert body["name"] == "user-77"

    assert :ok == Task.await(server_task, 5_000)
  end

  test "end to end returns the authenticated server voice presence snapshot" do
    room = "voice:550e8400-e29b-41d4-a716-446655440000"
    user_id = "e2e-user"
    server_id = "e2e-server"

    assert {:ok, nil} =
             VoiceSessionRegistry.switch(user_id, room, "Ada", server_id)

    conn =
      conn(:get, "/api/voice/participants?server_id=" <> server_id)
      |> put_req_header("x-user-id", user_id)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    started_at = VoiceSessionRegistry.room_started_at("550e8400-e29b-41d4-a716-446655440000")
    assert is_binary(started_at)

    assert Jason.decode!(conn.resp_body) == %{
             "server_id" => server_id,
             "channels" => [
               %{
                 "channel_id" => "550e8400-e29b-41d4-a716-446655440000",
                 "started_at" => started_at,
                 "participants" => [
                   %{"name" => "Ada", "participant_id" => user_id}
                 ]
               }
             ]
           }

    assert :ok = VoiceSessionRegistry.leave(user_id, room)
  end
end
