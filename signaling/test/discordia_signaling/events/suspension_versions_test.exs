defmodule DiscordiaSignaling.Events.SuspensionVersionsTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.SuspensionVersions

  defmodule Store do
    def newer_version(key, version) do
      versions = Application.get_env(:discordia_signaling, :test_versions, %{})
      {:ok, version > Map.get(versions, key, -1)}
    end

    def record_version(key, version) do
      versions = Application.get_env(:discordia_signaling, :test_versions, %{})
      current = Map.get(versions, key, -1)

      Application.put_env(
        :discordia_signaling,
        :test_versions,
        Map.put(versions, key, max(current, version))
      )

      :ok
    end
  end

  setup do
    previous = Application.get_env(:discordia_signaling, :voice_event_store)
    Application.put_env(:discordia_signaling, :voice_event_store, Store)
    Application.delete_env(:discordia_signaling, :test_versions)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:discordia_signaling, :voice_event_store, previous),
        else: Application.delete_env(:discordia_signaling, :voice_event_store)

      Application.delete_env(:discordia_signaling, :test_versions)
    end)

    :ok
  end

  test "any version is newer for a user never seen" do
    assert {:ok, true} = SuspensionVersions.newer?("user-1", 1)
  end

  test "a recorded version and lower ones are no longer newer" do
    :ok = SuspensionVersions.record("user-1", 3)

    assert {:ok, false} = SuspensionVersions.newer?("user-1", 3)
    assert {:ok, false} = SuspensionVersions.newer?("user-1", 2)
    assert {:ok, true} = SuspensionVersions.newer?("user-1", 4)
  end

  test "recording a lower version never lowers the stored one" do
    :ok = SuspensionVersions.record("user-1", 5)
    :ok = SuspensionVersions.record("user-1", 2)

    assert {:ok, false} = SuspensionVersions.newer?("user-1", 5)
  end

  test "versions are tracked per user" do
    :ok = SuspensionVersions.record("user-1", 5)

    assert {:ok, true} = SuspensionVersions.newer?("user-2", 1)
  end

  test "keys can be any term, so a server and a user with the same id don't collide" do
    :ok = SuspensionVersions.record({:server, "id-1"}, 4)

    assert {:ok, false} = SuspensionVersions.newer?({:server, "id-1"}, 4)
    assert {:ok, true} = SuspensionVersions.newer?({:server, "id-1"}, 5)
    assert {:ok, true} = SuspensionVersions.newer?("id-1", 1)
  end
end
