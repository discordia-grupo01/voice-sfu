defmodule DiscordiaSignalingWeb.VoicePresenceControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.Voice.VoiceSessionRegistry
  alias DiscordiaSignalingWeb.VoicePresenceController

  setup do
    previous_mode = System.get_env("VOICE_AUTHZ_MODE")
    previous_result = Application.get_env(:discordia_signaling, :test_room_service_result)
    System.put_env("VOICE_AUTHZ_MODE", "allow_authenticated")
    Application.put_env(:discordia_signaling, :test_room_service_result, :ok)

    Application.put_env(
      :discordia_signaling,
      :voice_presence_publisher,
      DiscordiaSignaling.TestVoicePresencePublisher
    )

    Application.put_env(:discordia_signaling, :test_presence_recipient, self())
    VoiceSessionRegistry.reconcile_snapshot([])
    VoiceSessionRegistry.participants()

    on_exit(fn ->
      if previous_mode do
        System.put_env("VOICE_AUTHZ_MODE", previous_mode)
      else
        System.delete_env("VOICE_AUTHZ_MODE")
      end

      if previous_result do
        Application.put_env(:discordia_signaling, :test_room_service_result, previous_result)
      else
        Application.delete_env(:discordia_signaling, :test_room_service_result)
      end
    end)

    :ok
  end

  test "returns active participants grouped by voice channel" do
    assert {:ok, nil} =
             VoiceSessionRegistry.switch(
               "presence-controller-user",
               "voice:room-1",
               "Ada",
               "server-1"
             )

    conn =
      VoicePresenceController.index(
        conn(:get, "/api/voice/participants"),
        %{"server_id" => "server-1"}
      )

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "server_id" => "server-1",
             "channels" => [
               %{
                 "channel_id" => "room-1",
                 "participants" => [
                   %{"name" => "Ada", "participant_id" => "presence-controller-user"}
                 ]
               }
             ]
           }

    assert :ok = VoiceSessionRegistry.leave("presence-controller-user", "voice:room-1")
  end

  test "rejects a request without a server id" do
    conn = VoicePresenceController.index(conn(:get, "/api/voice/participants"), %{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "server_id_required"}
  end
end
