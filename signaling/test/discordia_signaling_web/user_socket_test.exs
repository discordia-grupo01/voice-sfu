defmodule DiscordiaSignalingWeb.UserSocketTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignalingWeb.UserSocket

  test "accepts a socket connection in the current skeleton" do
    assert {:ok, socket} = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert socket.id == nil
  end

  test "does not expose a global socket id" do
    assert UserSocket.id(%Phoenix.Socket{}) == nil
  end
end
