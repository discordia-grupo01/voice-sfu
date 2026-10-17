defmodule DiscordiaSignaling.Voice.MembershipCacheTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.MembershipCache

  setup do
    MembershipCache.clear()
    on_exit(&MembershipCache.clear/0)
    :ok
  end

  defp counting(result) do
    agent = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    fun = fn ->
      Agent.update(agent, &(&1 + 1))
      result
    end

    {fun, fn -> Agent.get(agent, & &1) end}
  end

  test "keeps a positive answer while it is fresh" do
    {fun, calls} = counting(:ok)

    assert :ok = MembershipCache.fetch({"u", "s"}, 60_000, fun)
    assert :ok = MembershipCache.fetch({"u", "s"}, 60_000, fun)
    assert calls.() == 1
  end

  test "asks again once the entry has expired" do
    {fun, calls} = counting(:ok)

    assert :ok = MembershipCache.fetch({"u", "s"}, 20, fun)
    Process.sleep(40)
    assert :ok = MembershipCache.fetch({"u", "s"}, 20, fun)
    assert calls.() == 2
  end

  test "never keeps a refusal or a failure" do
    for result <- [:forbidden, :unavailable] do
      {fun, calls} = counting(result)

      assert ^result = MembershipCache.fetch({"u", result}, 60_000, fun)
      assert ^result = MembershipCache.fetch({"u", result}, 60_000, fun)
      assert calls.() == 2
    end
  end

  test "keeps one entry per key" do
    {fun, calls} = counting(:ok)

    MembershipCache.fetch({"u1", "s"}, 60_000, fun)
    MembershipCache.fetch({"u2", "s"}, 60_000, fun)
    MembershipCache.fetch({"u1", "s2"}, 60_000, fun)
    assert calls.() == 3
  end

  test "forget_user drops that user's memberships in every server and keeps the others" do
    {fun, calls} = counting(:ok)

    MembershipCache.fetch({"u1", "s1"}, 60_000, fun)
    MembershipCache.fetch({"u1", "s2"}, 60_000, fun)
    MembershipCache.fetch({"u2", "s1"}, 60_000, fun)
    assert calls.() == 3

    assert :ok = MembershipCache.forget_user("u1")

    MembershipCache.fetch({"u2", "s1"}, 60_000, fun)
    assert calls.() == 3

    MembershipCache.fetch({"u1", "s1"}, 60_000, fun)
    MembershipCache.fetch({"u1", "s2"}, 60_000, fun)
    assert calls.() == 5
  end

  test "forget_user on a user with nothing cached is a no-op" do
    assert :ok = MembershipCache.forget_user("nobody")
  end

  test "does not cache without a key or with a TTL of 0" do
    {fun, calls} = counting(:ok)

    MembershipCache.fetch(nil, 60_000, fun)
    MembershipCache.fetch(nil, 60_000, fun)
    MembershipCache.fetch({"u", "s"}, 0, fun)
    MembershipCache.fetch({"u", "s"}, 0, fun)
    assert calls.() == 4
  end
end
