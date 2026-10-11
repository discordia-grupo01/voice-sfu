defmodule DiscordiaSignaling.Voice.VoicePresenceReconcilerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.Voice.VoicePresenceReconciler
  alias DiscordiaSignaling.Voice.VoiceSessionRegistry

  setup do
    previous_service =
      Application.get_env(
        :discordia_signaling,
        :livekit_room_service,
        DiscordiaSignaling.Voice.LiveKitRoomService
      )

    Application.put_env(
      :discordia_signaling,
      :livekit_room_service,
      DiscordiaSignaling.TestLiveKitRoomService
    )

    Application.put_env(:discordia_signaling, :test_active_participants, {:ok, []})
    VoiceSessionRegistry.reconcile_snapshot([])
    VoiceSessionRegistry.participants()

    on_exit(fn ->
      Application.put_env(:discordia_signaling, :livekit_room_service, previous_service)
      Application.delete_env(:discordia_signaling, :test_active_participants)
    end)

    :ok
  end

  test "reconciles active LiveKit participants into the local registry" do
    Application.put_env(
      :discordia_signaling,
      :test_active_participants,
      {:ok,
       [
         %{
           identity: "reconciled-user",
           room_name: "voice:room-1",
           name: "Ada",
           server_id: nil
         }
       ]}
    )

    assert {:noreply, state} = VoicePresenceReconciler.handle_info(:reconcile, %{})
    assert state == %{}

    assert [%{"participant_id" => "reconciled-user", "room_id" => "room-1"}] =
             VoiceSessionRegistry.participants()
  end

  test "keeps the reconciler alive and retries when LiveKit is unavailable" do
    Application.put_env(
      :discordia_signaling,
      :test_active_participants,
      {:error, :unavailable}
    )

    assert {:noreply, state} = VoicePresenceReconciler.handle_info(:reconcile, %{attempts: 1})
    assert state == %{attempts: 1}
  end
end
