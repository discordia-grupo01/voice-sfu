defmodule DiscordiaSignaling.Events.AdminSignature do
  @moduledoc """
  Verifies the HMAC signature that admin attaches to its `admin.*` events.

  The signed text is `routing_key \\n event_id \\n subject_id \\n version \\n
  occurred_at`, hashed with HMAC-SHA256 using the secret shared with admin
  (`ADMIN_EVENTS_HMAC_SECRET`) and encoded as lowercase hexadecimal.
  `occurred_at` must be the string exactly as it arrived in the JSON.

  The subject is the `user_id` of the `admin.user_*` events and the `server_id`
  of the `admin.server_*` events. The routing key is part of the signed text, so
  an account event can't be replayed as a server event or the other way round.
  """

  @spec verify(String.t(), map(), String.t() | nil) :: boolean()
  def verify(routing_key, event, secret) when is_binary(routing_key) and is_map(event) do
    subject_key = subject_key(routing_key)

    with true <- non_empty_string?(secret),
         %{
           "event_id" => event_id,
           ^subject_key => subject_id,
           "version" => version,
           "occurred_at" => occurred_at,
           "signature" => signature
         } <- event,
         true <- non_empty_string?(event_id) and non_empty_string?(subject_id),
         true <- is_integer(version) and non_empty_string?(occurred_at),
         true <- non_empty_string?(signature) do
      expected =
        secret
        |> sign_text(routing_key, event_id, subject_id, version, occurred_at)
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(expected, signature)
    else
      _ -> false
    end
  end

  def verify(_routing_key, _event, _secret), do: false

  defp subject_key("admin.server_" <> _), do: "server_id"
  defp subject_key(_routing_key), do: "user_id"

  defp sign_text(secret, routing_key, event_id, subject_id, version, occurred_at) do
    text =
      Enum.join(
        [routing_key, event_id, subject_id, Integer.to_string(version), occurred_at],
        "\n"
      )

    :crypto.mac(:hmac, :sha256, secret, text)
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""
end
