defmodule DiscordiaSignaling.Voice.ScreenShareTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Voice.ScreenShare

  test "derives the companion identity from the user id" do
    assert ScreenShare.identity("user-1") == "user-1:screen"
  end

  test "recognizes companion identities" do
    assert ScreenShare.companion?("user-1:screen")
    refute ScreenShare.companion?("user-1")
    refute ScreenShare.companion?(":screen")
    refute ScreenShare.companion?(nil)
  end
end
