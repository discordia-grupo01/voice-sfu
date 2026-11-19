defmodule DiscordiaSignaling.BackoffTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Backoff

  test "grows exponentially to the configured maximum" do
    state = Backoff.init(%{})

    assert {1_000, state} = Backoff.next_delay(state)
    assert {2_000, state} = Backoff.next_delay(state)
    assert {4_000, state} = Backoff.next_delay(state)

    state = put_in(state.backoff.delay, 16_000)
    assert {16_000, state} = Backoff.next_delay(state)
    assert state.backoff.delay == 30_000
  end

  test "reset restores the initial delay" do
    state = %{backoff: %{delay: 30_000, max: 30_000}}
    assert %{backoff: %{delay: 1_000, max: 30_000}} = Backoff.reset(state)
  end
end
