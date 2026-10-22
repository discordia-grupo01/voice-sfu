defmodule DiscordiaSignaling.Events.SuspensionVersionsTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Events.SuspensionVersions

  setup do
    start_supervised!(SuspensionVersions)
    :ok
  end

  test "any version is newer for a user never seen" do
    assert SuspensionVersions.newer?("user-1", 1)
  end

  test "a recorded version and lower ones are no longer newer" do
    :ok = SuspensionVersions.record("user-1", 3)

    refute SuspensionVersions.newer?("user-1", 3)
    refute SuspensionVersions.newer?("user-1", 2)
    assert SuspensionVersions.newer?("user-1", 4)
  end

  test "recording a lower version never lowers the stored one" do
    :ok = SuspensionVersions.record("user-1", 5)
    :ok = SuspensionVersions.record("user-1", 2)

    refute SuspensionVersions.newer?("user-1", 5)
  end

  test "versions are tracked per user" do
    :ok = SuspensionVersions.record("user-1", 5)

    assert SuspensionVersions.newer?("user-2", 1)
  end
end
