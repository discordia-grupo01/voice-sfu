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

    assert_receive {:private_call, "private_call_accepted", caller_payload}
    assert caller_payload["token"] != accepted["token"]
    assert caller_payload["room_name"] == call.room_name
  end

  test "rejecting notifies the caller and removes the pending call" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:caller-4")

    assert {:ok, call} =
             PrivateCall.start("caller-4", "recipient-4", "conversation-4", "Bearer token")

    assert :ok = PrivateCall.reject(call.id, "recipient-4")
    assert_receive {:private_call, "private_call_rejected", %{"status" => "rejected"}}
    assert {:error, :call_not_found} = PrivateCall.get(call.id)
  end

  test "expiring an unanswered call notifies the caller" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:caller-timeout")

    assert {:ok, call} =
             PrivateCall.start(
               "caller-timeout",
               "recipient-timeout",
               "conversation-timeout",
               "******"
             )

    send(Process.whereis(PrivateCall), {:expire, call.id})

    assert_receive {:private_call, "private_call_missed", %{"status" => "ended"}}
    assert {:error, :call_not_found} = PrivateCall.get(call.id)
  end

  test "finishing an active call notifies the other participant" do
    Phoenix.PubSub.subscribe(DiscordiaSignaling.PubSub, "voice_user:caller-5")

    assert {:ok, call} =
             PrivateCall.start("caller-5", "recipient-5", "conversation-5", "Bearer token")

    assert {:ok, _accepted} = PrivateCall.accept(call.id, "recipient-5", "Bearer token")
    assert_receive {:private_call, "private_call_accepted", _payload}
    assert :ok = PrivateCall.finish(call.id, "recipient-5")
    assert_receive {:private_call, "private_call_ended", %{"status" => "ended"}}
  end

  defp restore(key, nil), do: Application.delete_env(:discordia_signaling, key)
  defp restore(key, value), do: Application.put_env(:discordia_signaling, key, value)
end
