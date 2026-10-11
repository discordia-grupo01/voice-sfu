Code.require_file("support/test_helpers.ex", __DIR__)
ExUnit.start(exclude: [:integration])

Application.put_env(
  :discordia_signaling,
  :livekit_room_service,
  DiscordiaSignaling.TestLiveKitRoomService
)
