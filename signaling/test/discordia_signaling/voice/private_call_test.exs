defmodule DiscordiaSignaling.Voice.PrivateCallTest do
  use ExUnit.Case, async: false

  alias DiscordiaSignaling.TestHelpers
  alias DiscordiaSignaling.Voice.PrivateCall

  setup do
    TestHelpers.put_livekit_config()
    previous_authorizer = Application.get_env(:discordia_signaling, :private_call_authorizer)
    previous_result = Application.get_env(:discordia_signaling, :test_private_call_authorization)

    Application.put_env(
      :discordia_signaling,
      :private_call_authorizer,
      DiscordiaSignaling.TestPrivateCallAuthorizer
    )

    Application.put_env(:discordia_signaling, :test_private_call_authorization, :ok)

    on_exit(fn ->
      restore(:private_call_authorizer, previous_authorizer)
      restore(:test_private_call_authorization, previous_result)
    end)

    :ok
  end

  test "starts a ringing call and notifies the recipient" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:recipient-1")

    assert {:ok, call} =
             PrivateCall.start("caller-1", "recipient-1", "conversation-1", "Bearer token")

    assert call.status == :ringing
    assert call.room_name == "private-call:" <> call.id
    assert_receive {:private_call, "private_call_incoming", %{"call_id" => call_id}}
    assert call_id == call.id
  end

  test "rejects a call when the direct conversation is blocked" do
    Application.put_env(
      :discordia_signaling,
      :test_private_call_authorization,
      {:error, :forbidden}
    )

    assert {:error, :forbidden} =
             PrivateCall.start("caller-2", "recipient-2", "conversation-2", "Bearer token")
  end

  test "acceptance gives both participants room-scoped tokens" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:caller-3")

    assert {:ok, call} =
             PrivateCall.start("caller-3", "recipient-3", "conversation-3", "Bearer token")

    assert {:ok, accepted} = PrivateCall.accept(call.id, "recipient-3", "Bearer token")
    assert accepted["status"] == "active"
    assert accepted["room_name"] == call.room_name
    assert accepted["token"] != nil
    assert accepted["url"] == "ws://test-livekit:7880"

    assert_receive {:private_call, "private_call_accepted", caller_payload}
    assert caller_payload["token"] != accepted["token"]
    assert caller_payload["room_name"] == call.room_name
    assert caller_payload["url"] == "ws://test-livekit:7880"
  end

  test "acceptance tells the recipient's other sessions without credentials" do
    assert {:ok, call} =
             PrivateCall.start("caller-7", "recipient-7", "conversation-7", "Bearer token")

    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:recipient-7")
    assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-7", "Bearer token")

    assert_receive {:private_call, "private_call_answered", payload}
    assert payload["call_id"] == call.id
    assert payload["status"] == "active"
    refute Map.has_key?(payload, "token")
    refute Map.has_key?(payload, "url")
  end

  test "ringing notifications do not carry LiveKit credentials" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:recipient-url")

    assert {:ok, _call} =
             PrivateCall.start("caller-url", "recipient-url", "conversation-url", "Bearer token")

    assert_receive {:private_call, "private_call_incoming", payload}
    refute Map.has_key?(payload, "token")
    refute Map.has_key?(payload, "url")
  end

  test "rejecting notifies both participants and removes the pending call" do
    assert {:ok, call} =
             PrivateCall.start("caller-4", "recipient-4", "conversation-4", "Bearer token")

    subscribe_users(["caller-4", "recipient-4"])
    assert :ok = PrivateCall.reject(call.id, "recipient-4")
    assert_received_twice("private_call_rejected", %{
      "status" => "rejected",
      "reason" => "declined",
      "ended_by" => "recipient-4"
    })

    assert {:error, :call_not_found} = PrivateCall.get(call.id)
  end

  test "the caller cancelling a ringing call is reported as cancelled" do
    assert {:ok, call} =
             PrivateCall.start("caller-6", "recipient-6", "conversation-6", "Bearer token")

    subscribe_users(["caller-6", "recipient-6"])
    assert :ok = PrivateCall.reject(call.id, "caller-6")

    assert_received_twice("private_call_rejected", %{
      "status" => "rejected",
      "reason" => "cancelled",
      "ended_by" => "caller-6"
    })
  end

  test "expiring an unanswered call notifies both participants" do
    assert {:ok, call} =
             PrivateCall.start(
               "caller-timeout",
               "recipient-timeout",
               "conversation-timeout",
               "******"
             )

    subscribe_users(["caller-timeout", "recipient-timeout"])
    send(Process.whereis(PrivateCall), {:expire, call.id})

    assert_received_twice("private_call_missed", %{
      "status" => "ended",
      "reason" => "missed",
      "ended_by" => nil
    })

    assert {:error, :call_not_found} = PrivateCall.get(call.id)
  end

  test "finishing an active call notifies both participants" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:caller-5")

    assert {:ok, call} =
             PrivateCall.start("caller-5", "recipient-5", "conversation-5", "Bearer token")

    assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-5", "Bearer token")
    assert_receive {:private_call, "private_call_accepted", _payload}

    subscribe_users(["recipient-5"])
    assert :ok = PrivateCall.finish(call.id, "recipient-5")
    assert_received_twice("private_call_ended", %{
      "status" => "ended",
      "reason" => "hangup",
      "ended_by" => "recipient-5"
    })
  end

  defp subscribe_users(user_ids) do
    Enum.each(user_ids, &Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:" <> &1))
  end

  defp assert_received_twice(event, expected) do
    for _ <- 1..2 do
      assert_receive {:private_call, ^event, payload}
      assert Map.take(payload, Map.keys(expected)) == expected
    end

    refute_receive {:private_call, ^event, _payload}, 50
  end

  defp restore(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
