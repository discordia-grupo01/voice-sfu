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

  test "creates a private call and returns its public payload" do
    conn =
      request("caller-create")
      |> Plug.Conn.put_req_header("authorization", "Bearer token")

    conn =
      PrivateCallController.create(conn, %{
        "recipient_id" => "recipient-create",
        "conversation_id" => "conversation-create"
      })

    assert conn.status == 201
    response = Jason.decode!(conn.resp_body)
    assert response["caller_id"] == "caller-create"
    assert response["recipient_id"] == "recipient-create"
    assert response["conversation_id"] == "conversation-create"
    assert response["status"] == "ringing"
  end

  test "rejects malformed create input" do
    conn = PrivateCallController.create(request("caller-invalid"), %{})

    assert conn.status == 400
    assert DiscordiaSignaling.TestHelpers.assert_error(conn, "INVALID_BODY")
  end

  test "creates a private call for a draft without a conversation id" do
    conn =
      request("caller-draft-controller")
      |> Plug.Conn.put_req_header("authorization", "Bearer token")

    conn =
      PrivateCallController.create(conn, %{
        "recipient_id" => "recipient-draft-controller"
      })

    assert conn.status == 201
    response = Jason.decode!(conn.resp_body)
    assert response["conversation_id"] == "conversation-recipient-draft-controller"
  end

  test "rejects and finishes calls through their controller actions" do
    rejected = start_call("caller-reject", "recipient-reject")

    reject_response =
      PrivateCallController.reject(request("recipient-reject"), %{"id" => rejected.id})

    assert reject_response.status == 204

    finished = start_call("caller-finish", "recipient-finish")
    assert {:ok, _accepted} = PrivateCall.accept(finished.id, "recipient-finish", "Bearer token")

    finish_response =
      PrivateCallController.finish(request("caller-finish"), %{"id" => finished.id})

    assert finish_response.status == 204
  end

  test "maps unknown action targets to not found" do
    reject_response =
      PrivateCallController.reject(request("caller-missing"), %{"id" => "missing-reject"})

    finish_response =
      PrivateCallController.finish(request("caller-missing"), %{"id" => "missing-finish"})

    assert reject_response.status == 404
    assert finish_response.status == 404
    assert DiscordiaSignaling.TestHelpers.assert_error(reject_response, "CALL_NOT_FOUND")
    assert DiscordiaSignaling.TestHelpers.assert_error(finish_response, "CALL_NOT_FOUND")
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
      assert DiscordiaSignaling.TestHelpers.assert_error(conn, "INVALID_CALL_STATE")
    end

    test "answers 404 for an unknown call" do
      conn = request("caller-ctl-3") |> PrivateCallController.screen_token(%{"id" => "missing"})

      assert conn.status == 404
      assert DiscordiaSignaling.TestHelpers.assert_error(conn, "CALL_NOT_FOUND")
    end

    test "answers 403 to someone outside the call" do
      call = start_call("caller-ctl-4", "recipient-ctl-4")
      assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-ctl-4", "Bearer token")

      conn = request("intruder") |> PrivateCallController.screen_token(%{"id" => call.id})

      assert conn.status == 403
      assert DiscordiaSignaling.TestHelpers.assert_error(conn, "VOICE_CALL_FORBIDDEN")
    end
  end

  test "an inconsistent call answers 500 INTERNAL_ERROR instead of a 403" do
    # Un evento replicado con el mismo caller y recipient deja una llamada corrupta.
    assert :ok =
             PrivateCall.replicate_event(%{
               "status" => "ringing",
               "call_id" => "self-call-500",
               "conversation_id" => "conversation-self",
               "caller_id" => "user-self",
               "recipient_id" => "user-self"
             })

    conn = request("user-self") |> PrivateCallController.reject(%{"id" => "self-call-500"})

    assert conn.status == 500
    error = TestHelpers.assert_error(conn, "INTERNAL_ERROR")
    refute inspect(error) =~ "invalid_call"
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
