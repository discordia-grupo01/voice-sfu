defmodule DiscordiaSignalingWeb.PrivateCallControllerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.PrivateCall
  alias DiscordiaSignalingWeb.PrivateCallController

  setup do
    TestHelpers.put_livekit_config()
    previous_authorizer = Application.get_env(:discordia_signaling, :private_call_authorizer)

    Application.put_env(
      :discordia_signaling,
      :private_call_authorizer,
      DiscordiaSignaling.TestPrivateCallAuthorizer
    )

    on_exit(fn ->
      if previous_authorizer do
        Application.put_env(:discordia_signaling, :private_call_authorizer, previous_authorizer)
      else
        Application.delete_env(:discordia_signaling, :private_call_authorizer)
      end
    end)

    :ok
  end

  describe "screen_token/2" do
    test "returns the companion token of an active call" do
      call = start_call("caller-ctl-1", "recipient-ctl-1")
      assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-ctl-1", "Bearer token")

      conn = request("recipient-ctl-1") |> PrivateCallController.screen_token(%{"id" => call.id})

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["identity"] == "recipient-ctl-1:screen"
      assert response["room_name"] == call.room_name
      assert response["url"] == "ws://test-livekit:7880"
      assert is_binary(response["token"])
    end

    test "answers 409 while the call is ringing" do
      call = start_call("caller-ctl-2", "recipient-ctl-2")

      conn = request("caller-ctl-2") |> PrivateCallController.screen_token(%{"id" => call.id})

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_call_state"}
    end

    test "answers 404 for an unknown call" do
      conn = request("caller-ctl-3") |> PrivateCallController.screen_token(%{"id" => "missing"})

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body) == %{"error" => "call_not_found"}
    end

    test "answers 403 to someone outside the call" do
      call = start_call("caller-ctl-4", "recipient-ctl-4")
      assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-ctl-4", "Bearer token")

      conn = request("intruder") |> PrivateCallController.screen_token(%{"id" => call.id})

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "voice_call_forbidden"}
    end
  end

  defp start_call(caller_id, recipient_id) do
    assert {:ok, call} =
             PrivateCall.start(
               caller_id,
               recipient_id,
               "conversation-" <> caller_id,
               "Bearer token"
             )

    call
  end

  defp request(user_id) do
    Plug.Conn.assign(conn(:post, "/api/voice/calls/id/screen-token"), :current_user_id, user_id)
  end
end
