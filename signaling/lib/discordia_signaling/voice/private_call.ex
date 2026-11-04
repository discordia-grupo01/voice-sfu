defmodule DiscordiaSignaling.Voice.PrivateCall do
  @moduledoc """
  Coordinates the short-lived control state of a one-to-one voice call.

  LiveKit remains responsible for media. This module only authorizes the
  contact, tracks the call lifecycle and broadcasts control notifications.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Voice.{LiveKitRoomService, LiveKitToken, VoiceAccess}

  @table :private_voice_calls
  @timeout_ms 30_000
  @abandoned_after_ms 30_000
  @pubsub DiscordiaSignaling.PubSub

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  def start(caller_id, recipient_id, conversation_id, authorization_header) do
    GenServer.call(
      __MODULE__,
      {:start, caller_id, recipient_id, conversation_id, authorization_header}
    )
  end

  def accept(call_id, user_id, authorization_header),
    do: GenServer.call(__MODULE__, {:accept, call_id, user_id, authorization_header})

  def reject(call_id, user_id), do: GenServer.call(__MODULE__, {:reject, call_id, user_id})
  def finish(call_id, user_id), do: GenServer.call(__MODULE__, {:finish, call_id, user_id})
  def get(call_id), do: GenServer.call(__MODULE__, {:get, call_id})
  def replicate_event(event), do: GenServer.call(__MODULE__, {:replicate_event, event})

  def reconcile(participants), do: GenServer.call(__MODULE__, {:reconcile, participants})

  @impl true
  def init(state) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, state}
  end

  @impl true
  def handle_call({:start, caller, recipient, conversation, auth}, _from, state) do
    with :ok <- validate_ids(caller, recipient, conversation),
         {:ok, _details} <- authorize_contact(caller, recipient, conversation, auth),
         :ok <- no_active_call(caller, recipient) do
      call_id = call_id()

      call = %{
        id: call_id,
        caller_id: caller,
        recipient_id: recipient,
        conversation_id: conversation,
        room_name: "private-call:" <> call_id,
        status: :ringing,
        inserted_at: System.system_time(:millisecond),
        incomplete_since: nil
      }

      :ets.insert(@table, {call_id, call})
      notify(recipient, "private_call_incoming", call_payload(call))
      publish_event(call, "ringing")
      Process.send_after(self(), {:expire, call_id}, @timeout_ms)
      {:reply, {:ok, call}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:accept, call_id, user_id, authorization_header}, _from, state) do
    with {:ok, call} <- fetch(call_id),
         :ok <- require_participant(call, user_id),
         :ok <- require_status(call, :ringing),
         {:ok, _details} <-
           authorize_contact(
             user_id,
             call.caller_id,
             call.conversation_id,
             authorization_header
           ),
         {:ok, token} <- token_for(call, user_id),
         {:ok, caller_token} <- token_for(call, call.caller_id) do
      accepted = %{call | status: :active}
      :ets.insert(@table, {call_id, accepted})
      notify(call.caller_id, "private_call_accepted", call_payload(accepted, caller_token))
      notify(call.recipient_id, "private_call_answered", call_payload(accepted))

      publish_event(accepted, "active")

      {:reply, {:ok, call_payload(accepted, token)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({action, call_id, user_id}, _from, state)
      when action in [:reject, :finish] do
    with {:ok, call} <- fetch(call_id),
         :ok <- require_participant(call, user_id),
         :ok <- require_status(call, action_status(action)) do
      :ets.delete(@table, call_id)
      event = if action == :reject, do: "private_call_rejected", else: "private_call_ended"
      status = if action == :reject, do: :rejected, else: :ended
      reason = end_reason(action, call, user_id)
      notify_participants(call, event, end_payload(%{call | status: status}, reason, user_id))

      publish_event(call, if(action == :reject, do: "rejected", else: "ended"), %{
        "reason" => reason,
        "ended_by" => user_id
      })

      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get, call_id}, _from, state) do
    {:reply, fetch(call_id), state}
  end

  def handle_call({:replicate_event, event}, _from, state) do
    {:reply, replicate_event_locally(event), state}
  end

  def handle_call({:reconcile, participants}, _from, state) do
    identities_by_room = Enum.group_by(participants, & &1.room_name, & &1.identity)
    now = System.system_time(:millisecond)

    for {_call_id, %{status: :active} = call} <- :ets.tab2list(@table) do
      reconcile_call(call, Map.get(identities_by_room, call.room_name, []), now)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:expire, call_id}, state) do
    case fetch(call_id) do
      {:ok, %{status: :ringing} = call} ->
        :ets.delete(@table, call_id)
        payload = end_payload(%{call | status: :ended}, "missed", nil)
        notify_participants(call, "private_call_missed", payload)
        publish_event(call, "missed", %{"reason" => "missed"})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp reconcile_call(call, identities, now) do
    cond do
      call.caller_id in identities and call.recipient_id in identities ->
        :ets.insert(@table, {call.id, %{call | incomplete_since: nil}})

      call.incomplete_since == nil ->
        :ets.insert(@table, {call.id, %{call | incomplete_since: now}})

      now - call.incomplete_since >= abandoned_after_ms() ->
        end_abandoned(call)

      true ->
        :ok
    end
  end

  defp end_abandoned(call) do
    :ets.delete(@table, call.id)
    ended = %{call | status: :ended}
    notify_participants(call, "private_call_ended", end_payload(ended, "disconnected", nil))
    publish_event(call, "ended", %{"reason" => "disconnected"})
    # Disconnects whoever is still in the room
    Task.start(fn -> room_service().delete_room(call.room_name) end)
  end

  defp abandoned_after_ms,
    do:
      Application.get_env(
        :discordia_signaling,
        :private_call_abandoned_after_ms,
        @abandoned_after_ms
      )

  defp room_service,
    do: Application.get_env(:discordia_signaling, :livekit_room_service, LiveKitRoomService)

  defp token_for(call, user_id) do
    LiveKitToken.issue(user_id, user_id, call.room_name)
  end

  defp authorize_contact(user_id, recipient_id, conversation_id, authorization_header) do
    authorizer().authorize_private_contact(
      user_id,
      recipient_id,
      conversation_id,
      authorization_header
    )
  end

  defp authorizer,
    do: Application.get_env(:discordia_signaling, :private_call_authorizer, VoiceAccess)

  defp no_active_call(caller, recipient) do
    active =
      :ets.tab2list(@table)
      |> Enum.any?(fn {_id, call} ->
        call.status in [:ringing, :active] and
          caller in [call.caller_id, call.recipient_id] and
          recipient in [call.caller_id, call.recipient_id]
      end)

    if active, do: {:error, :call_already_exists}, else: :ok
  end

  defp validate_ids(caller, recipient, conversation)
       when is_binary(caller) and caller != "" and is_binary(recipient) and recipient != "" and
              caller != recipient and is_binary(conversation) and conversation != "",
       do: :ok

  defp validate_ids(_, _, _), do: {:error, :invalid_input}

  defp fetch(call_id) do
    case :ets.lookup(@table, call_id) do
      [{^call_id, call}] -> {:ok, call}
      [] -> {:error, :call_not_found}
    end
  end

  defp replicate_event_locally(%{"status" => status} = event)
       when status in ["ringing", "active", "rejected", "missed", "ended"] do
    with {:ok, call} <- event_call(event) do
      case status do
        "ringing" -> replicate_ringing(call)
        "active" -> replicate_active(call, event)
        terminal -> replicate_terminal(call, terminal, event)
      end
    end
  end

  defp replicate_event_locally(_event), do: {:error, :invalid_event}

  defp event_call(event) do
    with call_id when is_binary(call_id) and call_id != "" <- event["call_id"],
         conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           event["conversation_id"],
         caller_id when is_binary(caller_id) and caller_id != "" <- event["caller_id"],
         recipient_id when is_binary(recipient_id) and recipient_id != "" <- event["recipient_id"] do
      {:ok,
       %{
         id: call_id,
         caller_id: caller_id,
         recipient_id: recipient_id,
         conversation_id: conversation_id,
         room_name: event["room_name"] || "private-call:" <> call_id,
         status: :ringing,
         inserted_at: System.system_time(:millisecond),
         incomplete_since: nil
       }}
    else
      _ -> {:error, :invalid_event}
    end
  end

  defp replicate_ringing(call) do
    case fetch(call.id) do
      {:ok, _existing} ->
        :ok

      {:error, :call_not_found} ->
        :ets.insert(@table, {call.id, call})
        notify(call.recipient_id, "private_call_incoming", call_payload(call))
        :ok
    end
  end

  defp replicate_active(call, _event) do
    case fetch(call.id) do
      {:ok, %{status: :active}} ->
        :ok

      {:ok, existing} ->
        active = %{existing | status: :active}
        :ets.insert(@table, {call.id, active})

        notify(
          call.caller_id,
          "private_call_accepted",
          call_payload(active, token_for(active, call.caller_id))
        )

        notify(call.recipient_id, "private_call_answered", call_payload(active))
        :ok

      {:error, :call_not_found} ->
        active = %{call | status: :active}
        :ets.insert(@table, {call.id, active})

        notify(
          call.caller_id,
          "private_call_accepted",
          call_payload(active, token_for(active, call.caller_id))
        )

        notify(call.recipient_id, "private_call_answered", call_payload(active))
        :ok
    end
  end

  defp replicate_terminal(call, status, event) do
    case fetch(call.id) do
      {:error, :call_not_found} ->
        :ok

      {:ok, existing} ->
        :ets.delete(@table, call.id)
        terminal_status = if status == "rejected", do: :rejected, else: :ended
        reason = event["reason"] || if(status == "missed", do: "missed", else: "hangup")
        ended_by = Map.get(event, "ended_by")

        event_name =
          if status == "rejected", do: "private_call_rejected", else: "private_call_" <> status

        notify_participants(
          existing,
          event_name,
          end_payload(%{existing | status: terminal_status}, reason, ended_by)
        )

        :ok
    end
  end

  defp require_participant(%{caller_id: user_id, recipient_id: user_id}, _),
    do: {:error, :invalid_call}

  defp require_participant(call, user_id)
       when call.caller_id == user_id or call.recipient_id == user_id,
       do: :ok

  defp require_participant(_, _), do: {:error, :forbidden}

  defp require_status(%{status: status}, status), do: :ok
  defp require_status(_, _), do: {:error, :invalid_call_state}

  defp action_status(:reject), do: :ringing
  defp action_status(:finish), do: :active

  defp end_reason(:reject, %{caller_id: user_id}, user_id), do: "cancelled"
  defp end_reason(:reject, _call, _user_id), do: "declined"
  defp end_reason(:finish, _call, _user_id), do: "hangup"

  defp end_payload(call, reason, ended_by) do
    call
    |> call_payload()
    |> Map.merge(%{"reason" => reason, "ended_by" => ended_by})
  end

  defp call_payload(call, token \\ nil) do
    payload = %{
      "call_id" => call.id,
      "conversation_id" => call.conversation_id,
      "caller_id" => call.caller_id,
      "recipient_id" => call.recipient_id,
      "room_name" => call.room_name,
      "status" => Atom.to_string(call.status)
    }

    if token,
      do: Map.merge(payload, %{"token" => token, "url" => LiveKitToken.url()}),
      else: payload
  end

  defp notify(user_id, event, payload),
    do:
      Phoenix.PubSub.broadcast(@pubsub, "voice_user:" <> user_id, {:private_call, event, payload})

  # Both users get the event so every open session of each one leaves the call,
  # including the other tabs of the user who triggered it.
  defp notify_participants(call, event, payload) do
    notify(call.caller_id, event, payload)
    notify(call.recipient_id, event, payload)
  end

  defp publish_event(call, status, extra \\ %{}) do
    DiscordiaSignaling.Voice.VoicePresencePublisher.publish(
      Map.merge(
        %{
          "event_type" => "voice.private_call",
          "event_id" => call_id(),
          "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "call_id" => call.id,
          "conversation_id" => call.conversation_id,
          "caller_id" => call.caller_id,
          "recipient_id" => call.recipient_id,
          "room_name" => call.room_name,
          "status" => status
        },
        extra
      )
    )
  end

  defp call_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
