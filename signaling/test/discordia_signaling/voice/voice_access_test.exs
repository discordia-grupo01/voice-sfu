defmodule DiscordiaSignaling.Voice.VoiceAccessTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoiceAccess

  setup do
    previous = System.get_env("VOICE_AUTHZ_MODE")

    on_exit(fn ->
      if previous, do: System.put_env("VOICE_AUTHZ_MODE", previous), else: System.delete_env("VOICE_AUTHZ_MODE")
    end)

    :ok
  end

  test "allows an authenticated user in development mode when configured" do
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")

    assert :ok = VoiceAccess.authorize("user-1", "room-1")
  end

  test "rejects access when authorization is not configured" do
    System.put_env("VOICE_AUTHZ_MODE", "deny")

    assert {:error, :not_configured} = VoiceAccess.authorize("user-1", "room-1")
  end

  test "rejects blank identities and rooms" do
    assert {:error, :forbidden} = VoiceAccess.authorize("", "room-1")
    assert {:error, :forbidden} = VoiceAccess.authorize("user-1", "")
  end
end
