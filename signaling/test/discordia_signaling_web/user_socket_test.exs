defmodule DiscordiaSignalingWeb.UserSocketTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignalingWeb.UserSocket
  alias DiscordiaSignaling.Voice.VoiceSocketTicket

  setup do
    previous_secret = System.get_env("JWT_SECRET")
    System.put_env("JWT_SECRET", "jwt-secret")

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("JWT_SECRET", previous_secret),
        else: System.delete_env("JWT_SECRET")
    end)

    :ok
  end

  test "accepts a socket connection with a valid voice ticket" do
    {:ok, ticket} = VoiceSocketTicket.issue("user-42")

    assert {:ok, socket} =
             UserSocket.connect(%{"ticket" => ticket}, %Phoenix.Socket{}, %{})

    assert socket.id == nil
    assert socket.assigns.current_user_id == "user-42"
  end

  test "rejects a socket connection without a valid voice ticket" do
    assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert :error = UserSocket.connect(%{"ticket" => "invalid"}, %Phoenix.Socket{}, %{})
  end

  test "does not expose a global socket id" do
    assert UserSocket.id(%Phoenix.Socket{}) == nil
  end
end
