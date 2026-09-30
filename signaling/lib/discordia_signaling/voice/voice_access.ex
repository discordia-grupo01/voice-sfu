defmodule DiscordiaSignaling.Voice.VoiceAccess do
  @moduledoc """
  Authorization boundary for LiveKit room access.

  The development mode allows any authenticated user so the first LiveKit
  flow can be exercised locally. Production must replace this policy with the
  server/channel membership check owned by the servers domain.
  """

  @spec authorize(String.t(), String.t()) :: :ok | {:error, atom()}
  def authorize(user_id, room_name)
      when is_binary(user_id) and user_id != "" and is_binary(room_name) and room_name != "" do
    case System.get_env("VOICE_AUTHZ_MODE", "deny") do
      "allow_authenticated" -> :ok
      _ -> {:error, :not_configured}
    end
  end

  def authorize(_user_id, _room_name), do: {:error, :forbidden}
end
