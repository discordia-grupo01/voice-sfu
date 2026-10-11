defmodule DiscordiaSignalingWeb.VoiceChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoiceChannel
  alias DiscordiaSignalingWeb.Endpoint

  @endpoint Endpoint

  setup do
    previous_room_service = Application.get_env(:discordia_signaling, :test_room_service_result)
    previous_publisher = Application.get_env(:discordia_signaling, :voice_presence_publisher)

    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    Application.put_env(
      :discordia_signaling,
      :voice_presence_publisher,
      DiscordiaSignaling.TestVoicePresencePublisher
    )

    VoiceSessionRegistry.reconcile_snapshot([])
    VoiceSessionRegistry.participants()

    on_exit(fn ->
      restore_env(:test_room_service_result, previous_room_service)
      restore_env(:voice_presence_publisher, previous_publisher)
      VoiceSessionRegistry.reconcile_snapshot([])
      VoiceSessionRegistry.participants()
    end)

    :ok
  end

  test "joins a voice room and assigns room and peer" do
    assert {:ok, socket} =
             VoiceChannel.join("voice:room-1", %{"peer_id" => "peer-1"}, %Phoenix.Socket{})

    assert socket.assigns.room_id == "room-1"
    assert socket.assigns.peer_id == "peer-1"
  end

  test "rejects an invalid join" do
    assert {:error, %{reason: "invalid_join"}} =
             VoiceChannel.join("text:room-1", %{}, %Phoenix.Socket{})

    assert {:error, %{reason: "invalid_join"}} =
             VoiceChannel.join("voice:room-1", %{"peer_id" => ""}, %Phoenix.Socket{})
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

  test "pushes presence events to the joined client" do
    {:ok, _, socket} =
      subscribe_and_join(
        socket(Endpoint, nil, %{}),
        VoiceChannel,
        "voice:room-1",
        %{"peer_id" => "peer-1"}
      )

    event = %{
      "event_type" => "voice.participant_joined",
      "event_id" => "event-1",
      "room_id" => "room-1",
      "participant_id" => "peer-2"
    }

    send(socket.channel_pid, {:voice_presence, event})

    assert_push("voice.participant_joined", ^event)
  end

  test "replicates the complete two-client presence flow through socket pushes" do
    {:ok, _, _first_socket} =
      subscribe_and_join(
        socket(Endpoint, nil, %{}),
        VoiceChannel,
        "voice:room-1",
        %{"peer_id" => "peer-1"}
      )

    assert {:ok, nil} =
             VoiceSessionRegistry.switch("peer-1", "voice:room-1", "Ada", "server-1")

    assert_push("voice.participant_joined", %{
      "event_type" => "voice.participant_joined",
      "participant_id" => "peer-1",
      "name" => "Ada",
      "room_id" => "room-1",
      "server_id" => "server-1"
    })

    {:ok, _, _second_socket} =
      subscribe_and_join(
        socket(Endpoint, nil, %{}),
        VoiceChannel,
        "voice:room-1",
        %{"peer_id" => "peer-2"}
      )

    assert {:ok, nil} =
             VoiceSessionRegistry.switch("peer-2", "voice:room-1", "Bea", "server-1")

    assert_push(
      "voice.participant_joined",
      %{
        "event_type" => "voice.participant_joined",
        "participant_id" => "peer-2",
        "name" => "Bea",
        "room_id" => "room-1",
        "server_id" => "server-1"
      } = second_join_event
    )

    assert_push("voice.participant_joined", ^second_join_event)

    assert :ok = VoiceSessionRegistry.leave("peer-1", "voice:room-1")

    assert_push(
      "voice.participant_left",
      %{
        "event_type" => "voice.participant_left",
        "participant_id" => "peer-1",
        "name" => "Ada",
        "room_id" => "room-1",
        "server_id" => "server-1"
      } = first_leave_event
    )

    assert_push("voice.participant_left", ^first_leave_event)

    assert VoiceSessionRegistry.participants("server-1") == [
             %{
               "participant_id" => "peer-2",
               "name" => "Bea",
               "room_id" => "room-1"
             }
           ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore_env(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
