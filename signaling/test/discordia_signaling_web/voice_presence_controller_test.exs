defmodule DiscordiaSignalingWeb.VoicePresenceControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.Voice.{MembershipCache, VoiceSessionRegistry}
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
    started_at = VoiceSessionRegistry.room_started_at("room-1")
    assert is_binary(started_at)

    assert Jason.decode!(conn.resp_body) == %{
             "server_id" => "server-1",
             "channels" => [
               %{
                 "channel_id" => "room-1",
                 "started_at" => started_at,
                 "participants" => [
                   %{"name" => "Ada", "participant_id" => "presence-controller-user"}
                 ]
               }
             ]
           }

    assert :ok = VoiceSessionRegistry.leave("presence-controller-user", "voice:room-1")
  end

  test "a call keeps its start while someone is still in the channel" do
    VoiceSessionRegistry.switch("presence-first", "voice:room-1", "Ada", "server-1")
    started_at = VoiceSessionRegistry.room_started_at("room-1")
    VoiceSessionRegistry.switch("presence-second", "voice:room-1", "Bea", "server-1")
    VoiceSessionRegistry.leave("presence-first", "voice:room-1")

    conn =
      VoicePresenceController.index(
        conn(:get, "/api/voice/participants"),
        %{"server_id" => "server-1"}
      )

    assert %{"channels" => [%{"channel_id" => "room-1", "started_at" => ^started_at}]} =
             Jason.decode!(conn.resp_body)

    VoiceSessionRegistry.leave("presence-second", "voice:room-1")
  end

  test "rejects a request without a server id" do
    conn = VoicePresenceController.index(conn(:get, "/api/voice/participants"), %{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "server_id_required"}
  end

  describe "with the servers API as the authorizer" do
    setup do
      previous = Application.get_env(:discordia_signaling, :servers)
      MembershipCache.clear()

      on_exit(fn ->
        Application.put_env(:discordia_signaling, :servers, previous)
        MembershipCache.clear()
      end)

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

    defp participants_request(authorization \\ "Bearer token", user_id \\ nil) do
      conn(:get, "/api/voice/participants")
      |> Plug.Conn.put_req_header("authorization", authorization)
      |> Plug.Conn.assign(:current_user_id, user_id)
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

    test "asks the lean membership endpoint, not the whole server" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      test_pid = self()

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        send(test_pid, {:request_line, request |> String.split("\r\n") |> hd()})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
        )

        :gen_tcp.close(socket)
      end)

      use_servers_api(port)
      assert participants_request().status == 200
      assert_receive {:request_line, "GET /v1/servers/server-1/membership HTTP/1.1"}
    end

    test "a confirmed member is remembered, so the next poll does not call servers" do
      use_servers_api(serve_once("200 OK"))

      assert participants_request("Bearer token", "user-cache").status == 200

      # Nothing answers any more: only the cache can produce this 200 (a real
      # call would hang until its 4 s timeout and end in 503).
      assert participants_request("Bearer token", "user-cache").status == 200
    end

    test "the memory is per user" do
      use_servers_api(serve_once("200 OK"))
      assert participants_request("Bearer token", "user-a").status == 200

      use_servers_api(serve_once("403 Forbidden"))
      assert participants_request("Bearer token", "user-b").status == 403
    end

    test "a refusal is not remembered" do
      use_servers_api(serve_once("403 Forbidden"))
      assert participants_request("Bearer token", "user-late").status == 403

      use_servers_api(serve_once("200 OK"))
      assert participants_request("Bearer token", "user-late").status == 200
    end

    test "the cache can be turned off" do
      Application.put_env(:discordia_signaling, :servers,
        url: "http://127.0.0.1:#{serve_once("200 OK")}",
        authz_mode: "servers_api",
        membership_cache_ttl_ms: 0
      )

      assert participants_request("Bearer token", "user-nocache").status == 200

      use_servers_api(serve_once("403 Forbidden"))
      assert participants_request("Bearer token", "user-nocache").status == 403
    end

    test "forbids a request without credentials" do
      use_servers_api(serve_once("200 OK"))

      assert participants_request("").status == 403
    end
  end
end
