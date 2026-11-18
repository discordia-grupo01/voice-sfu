defmodule DiscordiaSignaling.TestHelpers do
  import ExUnit.Assertions

  @code_pattern ~r/^[A-Z][A-Z0-9_]*$/

  @doc """
  Verifica el sobre de error completo (`error.code`, `error.message`, `error.details`)
  y devuelve el objeto `error` para seguir verificando detalles.
  """
  def assert_error(conn, code) do
    assert [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert Map.keys(body) == ["error"]
    %{"error" => error} = body
    assert is_binary(error["code"]) and error["code"] =~ @code_pattern
    assert is_binary(error["message"]) and error["message"] != ""
    assert is_map(error["details"])
    assert error["code"] == code
    error
  end

  def put_livekit_config(
        config \\ [
          api_key: "test-key",
          api_secret: "test-secret",
          url: "ws://test-livekit:7880",
          token_ttl_seconds: 3600
        ]
      ) do
    previous = Application.get_env(:discordia_signaling, :livekit)
    Application.put_env(:discordia_signaling, :livekit, config)

    ExUnit.Callbacks.on_exit(fn ->
      if previous do
        Application.put_env(:discordia_signaling, :livekit, previous)
      else
        Application.delete_env(:discordia_signaling, :livekit)
      end
    end)
  end

  def signed_access_token(claims \\ %{}) do
    default_claims = %{
      "sub" => "user-1",
      "exp" => System.system_time(:second) + 3600
    }

    jwt = JOSE.JWT.from_map(Map.merge(default_claims, claims))

    signed =
      JOSE.JWT.sign(JOSE.JWK.from_oct("jwt-secret"), %{"alg" => "HS256", "typ" => "JWT"}, jwt)

    {_, token} = JOSE.JWS.compact(signed)
    token
  end
end

defmodule DiscordiaSignaling.TestLiveKitRoomService do
  def active_participants do
    Application.get_env(:discordia_signaling, :test_active_participants, {:ok, []})
  end

  def remove_participant(room_name, identity) do
    send(self(), {:removed_participant, room_name, identity})
    Application.get_env(:discordia_signaling, :test_room_service_result, :ok)
  end

  def delete_room(_room_name) do
    Application.get_env(:discordia_signaling, :test_room_service_result, :ok)
  end

  def set_publish_permission(room_name, identity, can_publish) do
    send(self(), {:publish_permission, room_name, identity, can_publish})
    Application.get_env(:discordia_signaling, :test_room_service_result, :ok)
  end
end

defmodule DiscordiaSignaling.TestVoicePresencePublisher do
  def publish(event) do
    case Application.get_env(:discordia_signaling, :test_presence_recipient) do
      recipient when is_pid(recipient) ->
        send(recipient, {:voice_presence_published, event})

      _ ->
        :ok
    end

    :ok
  end
end

defmodule DiscordiaSignaling.TestPrivateCallAuthorizer do
  def authorize_private_contact(user_id, recipient_id, conversation_id, _authorization_header) do
    case Application.get_env(:discordia_signaling, :test_private_call_authorization, :ok) do
      :ok ->
        resolved_conversation =
          if is_binary(conversation_id) and conversation_id != "" do
            conversation_id
          else
            "550e8400-e29b-41d4-a716-446655440001"
          end

        {:ok,
         %{
           user_id: user_id,
           recipient_id: recipient_id,
           conversation_id: resolved_conversation
         }}

      result ->
        result
    end
  end
end
