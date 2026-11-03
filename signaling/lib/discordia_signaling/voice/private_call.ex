defmodule DiscordiaSignaling.Voice.PrivateCall do
  @moduledoc """
  Coordinates the short-lived control state of a one-to-one voice call.

  LiveKit remains responsible for media. This module only authorizes the
  contact, tracks the call lifecycle and broadcasts control notifications.
  """

  use GenServer
  require Logger

  alias DiscordiaSignaling.Voice.{LiveKitToken, VoiceAccess}

  @table :private_voice_calls
  @timeout_ms 30_000
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
        inserted_at: System.system_time(:millisecond)
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
      notify(other_participant(call, user_id), event, call_payload(%{call | status: status}))
      publish_event(call, if(action == :reject, do: "rejected", else: "ended"))
      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get, call_id}, _from, state) do
    {:reply, fetch(call_id), state}
  end

  @impl true
  def handle_info({:expire, call_id}, state) do
    case fetch(call_id) do
      {:ok, %{status: :ringing} = call} ->
        :ets.delete(@table, call_id)
        notify(call.caller_id, "private_call_missed", call_payload(%{call | status: :ended}))
        publish_event(call, "missed")

      _ ->
        :ok
    end

    {:noreply, state}
  end

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

  defp other_participant(call, user_id) do
    if call.caller_id == user_id, do: call.recipient_id, else: call.caller_id
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

  defp publish_event(call, status) do
    DiscordiaSignaling.Voice.VoicePresencePublisher.publish(%{
      "event_type" => "voice.private_call",
      "event_id" => call_id(),
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "call_id" => call.id,
      "conversation_id" => call.conversation_id,
      "caller_id" => call.caller_id,
      "recipient_id" => call.recipient_id,
      "status" => status
    })
  end

  defp call_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
