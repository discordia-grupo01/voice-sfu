defmodule DiscordiaSignaling.Voice.VoicePresencePublisherConfirmTest do
  use ExUnit.Case, async: true

  alias DiscordiaSignaling.Voice.VoicePresencePublisher

  test "el ack del broker confirma la publicación" do
    assert VoicePresencePublisher.confirmed(true) == :ok
  end

  test "un nack del broker es un error, para que el outbox deje el evento pendiente" do
    assert VoicePresencePublisher.confirmed(false) == {:error, :not_confirmed}
  end

  test "si el broker no responde a tiempo es un error" do
    assert VoicePresencePublisher.confirmed(:timeout) == {:error, :confirm_timeout}
  end
end
