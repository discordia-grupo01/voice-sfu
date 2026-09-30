defmodule DiscordiaSignalingWeb.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias DiscordiaSignalingWeb.Router

  test "health routes return ok" do
    for path <- ["/livez", "/readyz"] do
      conn = Router.call(conn(:get, path), Router.init([]))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    end
  end
end
