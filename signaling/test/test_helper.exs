Code.require_file("support/test_helpers.ex", __DIR__)
Code.require_file("support/stub_http.ex", __DIR__)
ExUnit.start(exclude: [:integration])

Application.put_env(
  :discordia_signaling,
  :livekit_room_service,
  DiscordiaSignaling.TestLiveKitRoomService
)

Application.put_env(:discordia_signaling, :reconcile_grace_ms, 0)

:ok =
  Supervisor.terminate_child(
    DiscordiaSignaling.Supervisor,
    DiscordiaSignaling.Voice.VoicePresenceReconciler
  )
