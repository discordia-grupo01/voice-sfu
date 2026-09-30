defmodule DiscordiaSignalingWeb.VoiceChannelTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignalingWeb.VoiceChannel

  test "joins a voice room and assigns room and peer" do
    assert {:ok, socket} = VoiceChannel.join("voice:room-1", %{"peer_id" => "peer-1"}, %Phoenix.Socket{})

    assert socket.assigns.room_id == "room-1"
    assert socket.assigns.peer_id == "peer-1"
  end

  test "rejects an invalid join" do
    assert {:error, %{reason: "invalid_join"}} = VoiceChannel.join("text:room-1", %{}, %Phoenix.Socket{})
    assert {:error, %{reason: "invalid_join"}} = VoiceChannel.join("voice:room-1", %{"peer_id" => ""}, %Phoenix.Socket{})
  end

  test "rejects signaling until the LiveKit migration bridge is not used" do
    {:ok, socket} = VoiceChannel.join("voice:room-1", %{"peer_id" => "peer-1"}, %Phoenix.Socket{})

    assert {:reply, {:error, %{reason: :not_configured}}, ^socket} =
             VoiceChannel.handle_in("offer", %{"sdp" => "offer"}, socket)
  end

  test "rejects unsupported signaling messages" do
    socket = %Phoenix.Socket{}

    assert {:reply, {:error, %{reason: "unsupported_signal"}}, ^socket} =
             VoiceChannel.handle_in("join", %{}, socket)
  end
end
