defmodule DiscordiaSignaling.ReadinessTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Readiness
  alias DiscordiaSignaling.StubHTTP
  alias DiscordiaSignaling.TestHelpers

  @livekit_ok [body: ~s({"rooms": []})]

  setup do
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_servers = Application.get_env(:discordia_signaling, :servers)

    on_exit(fn ->
      if previous_mode,
        do: System.put_env("VOICE_AUTHZ_MODE", previous_mode),
        else: System.delete_env("VOICE_AUTHZ_MODE")

      if previous_servers,
        do: Application.put_env(:discordia_signaling, :servers, previous_servers),
        else: Application.delete_env(:discordia_signaling, :servers)
    end)

    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    :ok
  end

  defp livekit(opts) do
    url = StubHTTP.start(Keyword.merge(@livekit_ok, opts))

    TestHelpers.put_livekit_config(
      api_key: "test-key",
      api_secret: "test-secret",
      url: url,
      token_ttl_seconds: 3600
    )
  end

  defp servers(url) do
    System.put_env("VOICE_AUTHZ_MODE", "servers_api")
    Application.put_env(:discordia_signaling, :servers, url: url, authz_mode: "servers_api")
  end

  test "is ready when LiveKit answers an authenticated request" do
    livekit(notify: self())

    assert Readiness.check() == :ok

    assert_receive {:stub_request, "POST", "/twirp/livekit.RoomService/ListRooms", headers}
    assert {"authorization", "Bearer " <> _token} = List.keyfind(headers, "authorization", 0)
  end

  test "is not ready when LiveKit answers with an error" do
    livekit(status: 500)

    assert Readiness.check() == {:error, ["livekit"]}
  end

  test "is not ready when LiveKit rejects the credentials" do
    livekit(status: 401)

    assert Readiness.check() == {:error, ["livekit"]}
  end

  test "is not ready when LiveKit cannot be reached" do
    TestHelpers.put_livekit_config(
      api_key: "test-key",
      api_secret: "test-secret",
      url: StubHTTP.closed_url(),
      token_ttl_seconds: 3600
    )

    assert Readiness.check() == {:error, ["livekit"]}
  end

  test "is not ready when LiveKit credentials are not configured" do
    TestHelpers.put_livekit_config(api_key: "", api_secret: "", url: "ws://localhost:7880")

    assert Readiness.check() == {:error, ["livekit"]}
  end

  test "gives up on a slow dependency instead of hanging the health check" do
    livekit(delay_ms: 5_000)

    {elapsed_us, result} = :timer.tc(&Readiness.check/0)

    assert result == {:error, ["livekit"]}
    assert elapsed_us < 3_000_000
  end

  test "does not look at servers unless authorization goes through it" do
    livekit([])
    Application.put_env(:discordia_signaling, :servers, url: StubHTTP.closed_url())

    assert Readiness.check() == :ok
  end

  test "checks servers liveness when authorization goes through servers" do
    livekit([])
    servers(StubHTTP.start(notify: self()))

    assert Readiness.check() == :ok

    assert_receive {:stub_request, "GET", "/livez", _headers}
  end

  test "uses the configured public servers readiness URL" do
    livekit([])
    health_url = StubHTTP.start(notify: self())

    Application.put_env(:discordia_signaling, :servers,
      url: "https://discordia-g1.duckdns.org",
      health_url: health_url,
      authz_mode: "servers_api"
    )

    System.put_env("VOICE_AUTHZ_MODE", "servers_api")
    assert Readiness.check() == :ok
    assert_receive {:stub_request, "GET", "/", _headers}
  end

  test "is not ready when servers answers with an error" do
    livekit([])
    servers(StubHTTP.start(status: 503))

    assert Readiness.check() == {:error, ["servers"]}
  end

  test "is not ready when servers cannot be reached" do
    livekit([])
    servers(StubHTTP.closed_url())

    assert Readiness.check() == {:error, ["servers"]}
  end

  test "is not ready when the servers url is missing" do
    livekit([])
    servers("")

    assert Readiness.check() == {:error, ["servers"]}
  end

  test "reports every dependency that failed, in order" do
    livekit(status: 500)
    servers(StubHTTP.start(status: 500))

    assert Readiness.check() == {:error, ["livekit", "servers"]}
  end
end
