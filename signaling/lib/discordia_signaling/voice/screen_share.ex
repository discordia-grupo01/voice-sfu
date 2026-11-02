defmodule DiscordiaSignaling.Voice.ScreenShare do
  @suffix ":screen"

  @spec identity(String.t()) :: String.t()
  def identity(user_id) when is_binary(user_id) and user_id != "", do: user_id <> @suffix

  @spec companion?(term()) :: boolean()
  def companion?(identity) when is_binary(identity) do
    String.ends_with?(identity, @suffix) and identity != @suffix
  end

  def companion?(_identity), do: false
end
