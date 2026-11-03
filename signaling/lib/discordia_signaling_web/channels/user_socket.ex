defmodule DiscordiaSignalingWeb.UserSocket do
  use Phoenix.Socket

  alias DiscordiaSignaling.Voice.VoiceSocketTicket

  channel("voice:*", DiscordiaSignalingWeb.VoiceChannel)
  channel("voice_server:*", DiscordiaSignalingWeb.VoiceChannel)
  channel("voice_user:*", DiscordiaSignalingWeb.VoiceChannel)

  @impl true
  def connect(%{"ticket" => ticket}, socket, _connect_info) when is_binary(ticket) do
    case VoiceSocketTicket.verify(ticket) do
      {:ok, user_id} -> {:ok, assign(socket, :current_user_id, user_id)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
