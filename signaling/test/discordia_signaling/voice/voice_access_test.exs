defmodule DiscordiaSignaling.Voice.VoiceAccessTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoiceAccess

  defmodule ReplicaStoreStub do
    def authorize(_channel_id, _user_id) do
      {:ok,
       [
         "server-1",
         "voice",
         "owner-1",
         ["role-1"],
         %{"role-1" => %{"permissions" => ["CONNECT"], "is_everyone" => false}},
         %{},
         Application.get_env(:discordia_signaling, :test_replica_muted),
         "Member"
       ]}
    end
  end

  setup do
    previous = System.get_env("VOICE_AUTHZ_MODE")
    previous_store = Application.get_env(:discordia_signaling, :replica_store)
    Application.put_env(:discordia_signaling, :replica_store, ReplicaStoreStub)

    on_exit(fn ->
      if previous,
        do: System.put_env("VOICE_AUTHZ_MODE", previous),
        else: System.delete_env("VOICE_AUTHZ_MODE")

      if previous_store do
        Application.put_env(:discordia_signaling, :replica_store, previous_store)
      else
        Application.delete_env(:discordia_signaling, :replica_store)
      end
    end)

    :ok
  end

  test "allows an authenticated user in development mode when configured" do
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")

    assert {:ok, "voice:550e8400-e29b-41d4-a716-446655440000"} =
             VoiceAccess.authorize("user-1", "550e8400-e29b-41d4-a716-446655440000")
  end

  test "returns the authenticated identity as the display name in development mode" do
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")

    assert {:ok, "voice:550e8400-e29b-41d4-a716-446655440000", "user-1"} =
             VoiceAccess.authorize_with_name("user-1", "550e8400-e29b-41d4-a716-446655440000")
  end

  test "keeps muted users in the room but disables publishing" do
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")

    assert {:ok, "voice:550e8400-e29b-41d4-a716-446655440000", "user-1", true} =
             VoiceAccess.authorize_with_permissions(
               "user-1",
               "550e8400-e29b-41d4-a716-446655440000"
             )
  end

  test "rejects access when authorization is not configured" do
    System.put_env("VOICE_AUTHZ_MODE", "deny")

    assert {:error, :not_configured} =
             VoiceAccess.authorize("user-1", "550e8400-e29b-41d4-a716-446655440000")
  end

  test "rejects blank identities and rooms" do
    assert {:error, :forbidden} =
             VoiceAccess.authorize("", "550e8400-e29b-41d4-a716-446655440000")

    assert {:error, :forbidden} = VoiceAccess.authorize("user-1", "")
  end

  test "allows publishing when the replica has no active mute" do
    System.put_env("VOICE_AUTHZ_MODE", "replica")
    Application.delete_env(:discordia_signaling, :test_replica_muted)

    assert {:ok, _room, _name, true, _server_id} =
             VoiceAccess.authorize_with_permissions(
               "user-1",
               "550e8400-e29b-41d4-a716-446655440000"
             )
  end

  test "disables publishing when the replica has an active mute" do
    System.put_env("VOICE_AUTHZ_MODE", "replica")
    Application.put_env(:discordia_signaling, :test_replica_muted, true)

    assert {:ok, _room, _name, false, _server_id} =
             VoiceAccess.authorize_with_permissions(
               "user-1",
               "550e8400-e29b-41d4-a716-446655440000"
             )
  end
end
