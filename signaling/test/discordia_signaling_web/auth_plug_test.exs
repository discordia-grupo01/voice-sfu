defmodule DiscordiaSignalingWeb.AuthPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignalingWeb.AuthPlug

  setup do
    previous_secret = System.get_env("JWT_SECRET")

    on_exit(fn ->
      if previous_secret, do: System.put_env("JWT_SECRET", previous_secret), else: System.delete_env("JWT_SECRET")
    end)

    System.put_env("JWT_SECRET", "jwt-secret")
    :ok
  end

  test "assigns the subject from a valid bearer token" do
    token = TestHelpers.signed_access_token(%{"sub" => "user-42"})
    conn = conn(:get, "/") |> put_req_header("authorization", "Bearer " <> token) |> AuthPlug.call([])

    refute conn.halted
    assert conn.assigns.current_user_id == "user-42"
  end

  test "rejects expired tokens" do
    token = TestHelpers.signed_access_token(%{"exp" => System.system_time(:second) - 1})
    conn = conn(:get, "/") |> put_req_header("authorization", "Bearer " <> token) |> AuthPlug.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "rejects tokens without a subject" do
    token = TestHelpers.signed_access_token(%{"sub" => nil})
    conn = conn(:get, "/") |> put_req_header("authorization", "Bearer " <> token) |> AuthPlug.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "allows the development user header without a bearer token" do
    conn = conn(:get, "/") |> put_req_header("x-user-id", "dev-user") |> AuthPlug.call([])

    refute conn.halted
    assert conn.assigns.current_user_id == "dev-user"
  end

  test "rejects requests without credentials" do
    conn = conn(:get, "/") |> AuthPlug.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
