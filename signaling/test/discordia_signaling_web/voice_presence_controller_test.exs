defmodule DiscordiaSignalingWeb.VoicePresenceControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoicePresenceController

  setup do
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    Application.put_env(
      :discordia_signaling,
      :voice_presence_publisher,
      DiscordiaSignaling.TestVoicePresencePublisher
    )

    Application.put_env(:discordia_signaling, :test_presence_recipient, self())
    VoiceSessionRegistry.reconcile_snapshot([])
    VoiceSessionRegistry.participants()

    on_exit(fn ->
      if previous_mode do
        System.put_env("VOICE_AUTHZ_MODE", previous_mode)
      else
        System.delete_env("VOICE_AUTHZ_MODE")
      end

      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end
    end)

    :ok
  end

  test "returns active participants grouped by voice channel" do
    assert {:ok, nil} =
             VoiceSessionRegistry.switch(
               "presence-controller-user",
               "voice:room-1",
               "Ada",
               "server-1"
             )

    conn =
      VoicePresenceController.index(
        conn(:get, "/api/voice/participants"),
        %{"server_id" => "server-1"}
      )

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "server_id" => "server-1",
             "channels" => [
               %{
                 "channel_id" => "room-1",
                 "participants" => [
                   %{"name" => "Ada", "participant_id" => "presence-controller-user"}
                 ]
               }
             ]
           }

    assert :ok = VoiceSessionRegistry.leave("presence-controller-user", "voice:room-1")
  end

  test "rejects a request without a server id" do
    conn = VoicePresenceController.index(conn(:get, "/api/voice/participants"), %{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "server_id_required"}
  end

  describe "with the servers API as the authorizer" do
    setup do
      previous = Application.get_env(:discordia_signaling, :servers)
      on_exit(fn -> Application.put_env(:discordia_signaling, :servers, previous) end)
      :ok
    end

    # Serves one canned HTTP response, then closes.
    defp serve_once(status_line) do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status_line}\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
        )

        :gen_tcp.close(socket)
      end)

      port
    end

    defp use_servers_api(port) do
      Application.put_env(:discordia_signaling, :servers,
        url: "http://127.0.0.1:#{port}",
        authz_mode: "servers_api"
      )
    end

    defp participants_request(authorization \\ "Bearer token") do
      conn(:get, "/api/voice/participants")
      |> Plug.Conn.put_req_header("authorization", authorization)
      |> VoicePresenceController.index(%{"server_id" => "server-1"})
    end

    test "lets a member of the server see the participants" do
      use_servers_api(serve_once("200 OK"))

      assert participants_request().status == 200
    end

    test "forbids a user the servers API rejects" do
      use_servers_api(serve_once("403 Forbidden"))

      conn = participants_request()

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "voice_forbidden"}
    end

    test "answers unavailable, not forbidden, when the servers API fails" do
      use_servers_api(serve_once("500 Internal Server Error"))

      conn = participants_request()

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "voice_unavailable"}
    end

    test "answers unavailable when the servers API cannot be reached" do
      {:ok, listen} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      use_servers_api(port)

      conn = participants_request()

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) == %{"error" => "voice_unavailable"}
    end

    test "forbids a request without credentials" do
      use_servers_api(serve_once("200 OK"))

      assert participants_request("").status == 403
    end
  end
end
