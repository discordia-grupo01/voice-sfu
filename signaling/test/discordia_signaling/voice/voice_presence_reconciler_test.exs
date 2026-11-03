defmodule DiscordiaSignaling.Voice.VoicePresenceReconcilerTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.PrivateCall
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

  test "announces participants removed from LiveKit to local presence subscribers" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_server:server-1")

    assert {:ok, nil} =
             VoiceSessionRegistry.switch(
               "stale-user",
               "voice:room-1",
               "Ada",
               "server-1"
             )

    assert_receive {:voice_presence, %{"event_type" => "voice.participant_joined"}}

    Application.put_env(:discordia_signaling, :test_active_participants, {:ok, []})
    assert {:noreply, %{}} = VoicePresenceReconciler.handle_info(:reconcile, %{})

    assert_receive {:voice_presence,
                    %{
                      "event_type" => "voice.participant_left",
                      "participant_id" => "stale-user",
                      "room_id" => "room-1",
                      "server_id" => "server-1"
                    }}

    assert VoiceSessionRegistry.participants("server-1") == []
  end

  test "ends private calls whose participants are gone from LiveKit" do
    TestHelpers.put_livekit_config()
    previous_authorizer = Application.get_env(:discordia_signaling, :private_call_authorizer)

    Application.put_env(
      :discordia_signaling,
      :private_call_authorizer,
      DiscordiaSignaling.TestPrivateCallAuthorizer
    )

    Application.put_env(:discordia_signaling, :private_call_abandoned_after_ms, 0)

    on_exit(fn ->
      restore(:private_call_authorizer, previous_authorizer)
      Application.delete_env(:discordia_signaling, :private_call_abandoned_after_ms)
    end)

    assert {:ok, call} =
             PrivateCall.start("reconcile-caller", "reconcile-recipient", "conv-r", "Bearer t")

    assert {:ok, _accepted} = PrivateCall.accept(call.id, "reconcile-recipient", "Bearer t")

    assert {:noreply, %{}} = VoicePresenceReconciler.handle_info(:reconcile, %{})
    assert {:noreply, %{}} = VoicePresenceReconciler.handle_info(:reconcile, %{})
    assert {:error, :call_not_found} = PrivateCall.get(call.id)
  end

  defp restore(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
