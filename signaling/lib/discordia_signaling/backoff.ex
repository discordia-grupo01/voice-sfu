defmodule DiscordiaSignaling.Backoff do
  @moduledoc false

  @initial 1_000
  @max 30_000

  def init(state), do: Map.put(state, :backoff, %{delay: @initial, max: @max})

  def reset(state), do: Map.put(state, :backoff, %{delay: @initial, max: @max})

  def next_delay(state) do
    %{delay: delay, max: max_delay} =
      Map.get(state, :backoff, %{delay: @initial, max: @max})

    next_state =
      Map.put(state, :backoff, %{delay: min(delay * 2, max_delay), max: max_delay})

    {delay, next_state}
  end
end
