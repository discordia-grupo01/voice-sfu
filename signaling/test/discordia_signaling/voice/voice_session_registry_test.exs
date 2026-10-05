defmodule DiscordiaSignaling.Voice.VoiceSessionRegistryTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  setup do
    VoiceSessionRegistry.leave("user-1", "voice:room-1")
    VoiceSessionRegistry.leave("user-1", "voice:room-2")
    :ok
  end

  test "replaces the previous room for an identity" do
    assert {:ok, nil} = VoiceSessionRegistry.switch("user-1", "voice:room-1")
    assert {:ok, "voice:room-1"} = VoiceSessionRegistry.switch("user-1", "voice:room-2")
    assert VoiceSessionRegistry.active_room("user-1") == "voice:room-2"
  end

  test "does not remove a newer room when an older room leaves" do
    VoiceSessionRegistry.switch("user-1", "voice:room-1")
    VoiceSessionRegistry.switch("user-1", "voice:room-2")

    assert :ok = VoiceSessionRegistry.leave("user-1", "voice:room-1")
    assert VoiceSessionRegistry.active_room("user-1") == "voice:room-2"
  end
end
