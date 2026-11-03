defmodule DiscordiaSignalingWeb.VoiceChannel do
  use Phoenix.Channel

  @pubsub DiscordiaSignaling.PubSub

  alias DiscordiaSignaling.Voice.SfuBridge

  @signal_types ~w(offer answer candidate)

  @impl true
  def join("voice:" <> room_id, %{"peer_id" => peer_id}, socket)
      when is_binary(room_id) and is_binary(peer_id) and byte_size(peer_id) > 0 do
    Phoenix.PubSub.subscribe(@pubsub, "voice:#{room_id}")
    {:ok, assign(socket, room_id: room_id, peer_id: peer_id)}
  end

  def join("voice_server:" <> server_id, _params, socket)
      when is_binary(server_id) and byte_size(server_id) > 0 do
    Phoenix.PubSub.subscribe(@pubsub, "voice_server:#{server_id}")
    {:ok, assign(socket, server_id: server_id, presence_only: true)}
  end

  def join("voice_user:" <> user_id, _params, %{assigns: %{current_user_id: user_id}} = socket)
      when is_binary(user_id) and byte_size(user_id) > 0 do
    Phoenix.PubSub.subscribe(@pubsub, "voice_user:#{user_id}")
    {:ok, assign(socket, user_id: user_id, user_only: true)}
  end

  def join("voice_user:" <> _user_id, _params, _socket), do: {:error, %{reason: "forbidden"}}

  def join(_topic, _params, _socket), do: {:error, %{reason: "invalid_join"}}

  @impl true
  def handle_in(
        type,
        payload,
        %{assigns: %{room_id: room_id, peer_id: peer_id}} = socket
      )
      when type in @signal_types and is_map(payload) do
    message = %{
      "type" => type,
      "room_id" => room_id,
      "peer_id" => peer_id,
      "data" => payload
    }

    case SfuBridge.forward(message) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(_type, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported_signal"}}, socket}

  @impl true
  def handle_info({:voice_presence, event}, socket) do
    push(socket, event["event_type"], event)
    {:noreply, socket}
  end

  def handle_info({:private_call, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end
end
