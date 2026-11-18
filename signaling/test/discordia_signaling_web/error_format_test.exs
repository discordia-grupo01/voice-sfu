defmodule DiscordiaSignalingWeb.ErrorFormatTest do
  @moduledoc "Los errores del framework salen con el sobre común, pasando por el endpoint real."
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias DiscordiaSignaling.TestHelpers

  @endpoint DiscordiaSignalingWeb.Endpoint
  @code_pattern ~r/^[A-Z][A-Z0-9_]*$/

  setup do
    previous_secret = System.get_env("JWT_SECRET")
    System.put_env("JWT_SECRET", "jwt-secret")

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("JWT_SECRET", previous_secret),
        else: System.delete_env("JWT_SECRET")
    end)

    :ok
  end

  defp assert_envelope(body, code) do
    assert %{"error" => error} = Jason.decode!(body)
    assert is_binary(error["code"]) and error["code"] =~ @code_pattern
    assert is_binary(error["message"]) and error["message"] != ""
    assert is_map(error["details"])
    assert error["code"] == code
    error
  end

  defp bearer(conn) do
    token = TestHelpers.signed_access_token(%{"sub" => "user-1"})
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "an unknown route answers 404 NOT_FOUND" do
    conn = get(build_conn(), "/api/no-existe")

    assert conn.status == 404
    TestHelpers.assert_error(conn, "NOT_FOUND")
  end

  test "a wrong method on an existing route answers 404 NOT_FOUND (Phoenix has no 405)" do
    conn = get(build_conn(), "/api/voice/token")

    assert conn.status == 404
    TestHelpers.assert_error(conn, "NOT_FOUND")
  end

  test "a malformed JSON body answers 400 INVALID_BODY with empty details" do
    {400, _headers, body} =
      assert_error_sent(400, fn ->
        build_conn()
        |> bearer()
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, :post, "/api/voice/token", "{no es json")
      end)

    error = assert_envelope(body, "INVALID_BODY")
    assert error["details"] == %{}
  end

  test "a missing token answers 401 UNAUTHORIZED through the whole endpoint" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/voice/token", Jason.encode!(%{"channel_id" => "x"}))

    assert conn.status == 401
    TestHelpers.assert_error(conn, "UNAUTHORIZED")
  end

  test "an unhandled exception renders INTERNAL_ERROR without leaking the internal reason" do
    previous = Application.get_env(:discordia_signaling, :servers)
    # Sin url, la consulta de pertenencia revienta con ArgumentError: un 500 real.
    Application.put_env(:discordia_signaling, :servers, authz_mode: "servers_api")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:discordia_signaling, :servers, previous),
        else: Application.delete_env(:discordia_signaling, :servers)
    end)

    {500, _headers, body} =
      assert_error_sent(500, fn ->
        build_conn()
        |> bearer()
        |> put_req_header("authorization", "Bearer " <> TestHelpers.signed_access_token())
        |> get("/api/voice/participants?server_id=srv-1")
      end)

    refute body =~ "ArgumentError"
    assert_envelope(body, "INTERNAL_ERROR")
  end
end
