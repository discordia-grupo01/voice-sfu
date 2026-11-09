defmodule DiscordiaSignalingWeb.HealthControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias DiscordiaSignaling.StubHTTP
  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignalingWeb.Router

  setup do
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")

    on_exit(fn ->
      if previous_mode,
        do: System.put_env("VOICE_AUTHZ_MODE", previous_mode),
        else: System.delete_env("VOICE_AUTHZ_MODE")
    end)

    :ok
  end

  defp livekit_at(url) do
    TestHelpers.put_livekit_config(
      api_key: "test-key",
      api_secret: "test-secret",
      url: url,
      token_ttl_seconds: 3600
    )
  end

  defp get(path), do: Router.call(conn(:get, path), Router.init([]))

  test "livez answers without touching any dependency" do
    livekit_at(StubHTTP.start(notify: self()))

    conn = get("/livez")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    refute_receive {:stub_request, _method, _path, _headers}, 100
  end

  test "livez keeps answering when LiveKit is down" do
    livekit_at(StubHTTP.closed_url())

    assert get("/livez").status == 200
  end

  test "readyz is 200 when its dependencies answer" do
    livekit_at(StubHTTP.start(body: ~s({"rooms": []})))

    conn = get("/readyz")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ready"}
  end

  test "readyz is 503 and names what failed when LiveKit is down" do
    livekit_at(StubHTTP.closed_url())

    log =
      capture_log(fn ->
        conn = get("/readyz")

        assert conn.status == 503

        assert Jason.decode!(conn.resp_body) == %{
                 "status" => "unavailable",
                 "failed" => ["livekit"]
               }
      end)

    assert log =~ "readyz_failed"
  end

  test "livez and readyz are different actions, so one cannot answer for the other" do
    livekit_at(StubHTTP.closed_url())

    assert get("/livez").status == 200
    assert get("/readyz").status == 503
  end
end
