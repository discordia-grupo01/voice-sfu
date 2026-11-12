defmodule DiscordiaSignaling.Voice.VoiceAccess do
  require Logger

  @moduledoc """
  Authorization boundary for LiveKit room access.

  The development mode allows any authenticated user so the first LiveKit
  flow can be exercised locally. Production must replace this policy with the
  server/channel membership check owned by the servers domain.
  """

  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  alias DiscordiaSignaling.Voice.{ReplicaPermissions, ReplicaStore}

  @spec authorize(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def authorize(user_id, channel_id, authorization_header \\ nil)

  def authorize(user_id, channel_id, authorization_header)
      when is_binary(user_id) and user_id != "" and is_binary(channel_id) and channel_id != "" do
    case authorize_with_permissions(user_id, channel_id, authorization_header) do
      {:ok, room_name, _name, _can_publish} -> {:ok, room_name}
      error -> error
    end
  end

  def authorize(_user_id, _channel_id, _authorization_header), do: {:error, :forbidden}

  @spec authorize_with_name(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()} | {:error, atom()}
  def authorize_with_name(user_id, channel_id, authorization_header \\ nil) do
    case authorize_with_permissions(user_id, channel_id, authorization_header) do
      {:ok, room_name, name, _can_publish} -> {:ok, room_name, name}
      error -> error
    end
  end

  @spec authorize_with_permissions(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t(), boolean()} | {:error, atom()}
  def authorize_with_permissions(user_id, channel_id, authorization_header \\ nil)

  def authorize_with_permissions(user_id, channel_id, authorization_header)
      when is_binary(user_id) and user_id != "" and is_binary(channel_id) and channel_id != "" do
    if Regex.match?(@uuid_pattern, channel_id) do
      case authz_mode() do
        "allow_authenticated" ->
          {:ok, room_name(channel_id), user_id, true}

        "servers_api" ->
          case authorize_with_servers(user_id, channel_id, authorization_header) do
            {:ok, room_name, name, can_publish, _server_id} ->
              {:ok, room_name, name, can_publish}

            error ->
              error
          end

        mode when mode in ["replica", "replica_shadow"] ->
          authorize_with_replica(user_id, channel_id, mode, authorization_header)

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :forbidden}
    end
  end

  def authorize_with_permissions(_user_id, _channel_id, _authorization_header),
    do: {:error, :forbidden}

  @spec authz_mode() :: String.t()
  def authz_mode do
    System.get_env(
      "VOICE_AUTHZ_MODE",
      Application.get_env(:discordia_signaling, :servers, [])[:authz_mode] || "deny"
    )
  end

  defp room_name(channel_id), do: "voice:" <> channel_id

  defp authorize_with_servers(_user_id, _channel_id, authorization_header)
       when not is_binary(authorization_header) or authorization_header == "" do
    {:error, :forbidden}
  end

  defp authorize_with_servers(user_id, channel_id, authorization_header) do
    base_url = Application.get_env(:discordia_signaling, :servers, [])[:url]
    url = String.to_charlist(base_url <> "/v1/channels/" <> channel_id <> "/voice-access")
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    case :httpc.request(:get, {url, headers}, [connect_timeout: 2_000, timeout: 4_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"allowed" => true} = response} ->
            name = Map.get(response, "name", user_id)
            can_publish = Map.get(response, "muted") != true

            {:ok, room_name(channel_id),
             if(is_binary(name) and name != "", do: name, else: user_id), can_publish,
             Map.get(response, "server_id")}

          _ ->
            {:error, :forbidden}
        end

      {:ok, {{_, status, _}, _headers, _body}} when status in [401, 403, 404] ->
        {:error, :forbidden}

      _ ->
        {:error, :not_configured}
    end
  end

  defp authorize_with_replica(user_id, channel_id, "replica", _authorization_header) do
    case ReplicaStore.authorize(channel_id, user_id) do
      {:ok, [server_id, "voice", owner_id, role_ids, roles, overrides, muted, name]} ->
        permissions =
          ReplicaPermissions.effective(
            owner_id == user_id,
            decode_json(role_ids, []),
            decode_json(roles, %{}),
            decode_json(overrides, %{})
          )

        if ReplicaPermissions.can?(permissions, "CONNECT") do
          {:ok, room_name(channel_id), profile_name(name, user_id), muted == true, server_id}
        else
          {:error, :forbidden}
        end

      {:ok, _row} ->
        {:error, :forbidden}

      {:error, :unavailable} ->
        {:error, :not_configured}

      {:error, _reason} ->
        {:error, :forbidden}
    end
  end

  defp authorize_with_replica(user_id, channel_id, "replica_shadow", authorization_header) do
    replica = authorize_with_replica(user_id, channel_id, "replica", authorization_header)
    servers = authorize_with_servers(user_id, channel_id, authorization_header)

    if normalize_result(replica) != normalize_result(servers) do
      Logger.warning("voice_replica_authorization_mismatch",
        user_id: user_id,
        channel_id: channel_id,
        replica: inspect(normalize_result(replica)),
        servers: inspect(normalize_result(servers))
      )
    end

    servers
  end

  defp normalize_result({:ok, _room, _name, can_publish, server_id}),
    do: {:ok, can_publish, server_id}

  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(_), do: {:error, :invalid}

  defp decode_json(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> default
    end
  end

  defp decode_json(value, _default) when is_map(value) or is_list(value), do: value
  defp decode_json(_value, default), do: default

  defp profile_name(name, _user_id) when is_binary(name) and name != "", do: name
  defp profile_name(_name, user_id), do: user_id

  @spec authorize_with_details(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def authorize_with_details(user_id, channel_id, authorization_header \\ nil)

  def authorize_with_details(user_id, _channel_id, _authorization_header)
      when not is_binary(user_id) or user_id == "",
      do: {:error, :forbidden}

  def authorize_with_details(user_id, channel_id, authorization_header) do
    with {:ok, room_name, name, can_publish, server_id} <-
           authorize_details(user_id, channel_id, authorization_header) do
      {:ok,
       %{
         room_name: room_name,
         name: name,
         can_publish: can_publish,
         server_id: server_id
       }}
    end
  end

  @spec authorize_private_contact(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def authorize_private_contact(user_id, recipient_id, conversation_id, authorization_header)
      when is_binary(user_id) and is_binary(recipient_id) and is_binary(conversation_id) do
    if user_id == recipient_id do
      {:error, :forbidden}
    else
      case private_contact_url(recipient_id, conversation_id) do
        {:ok, url} -> request_private_contact(url, authorization_header)
        :error -> {:error, :not_configured}
      end
    end
  end

  def authorize_private_contact(_, _, _, _), do: {:error, :forbidden}

  defp authorize_details(user_id, channel_id, authorization_header) do
    if Regex.match?(@uuid_pattern, channel_id) do
      case authz_mode() do
        "allow_authenticated" ->
          {:ok, room_name(channel_id), user_id, true, nil}

        "servers_api" ->
          authorize_with_servers(user_id, channel_id, authorization_header)

        mode when mode in ["replica", "replica_shadow"] ->
          authorize_with_replica(user_id, channel_id, mode, authorization_header)

        _ ->
          {:error, :not_configured}
      end
    else
      {:error, :forbidden}
    end
  end

  defp private_contact_url(recipient_id, conversation_id) do
    base_url = Application.get_env(:discordia_signaling, :messaging, [])[:url]

    if is_binary(base_url) and base_url != "" do
      {:ok,
       String.to_charlist(
         base_url <>
           "/v1/voice-access/" <>
           URI.encode(recipient_id) <>
           "?conversation_id=" <>
           URI.encode(conversation_id)
       )}
    else
      :error
    end
  end

  defp request_private_contact(_url, authorization_header)
       when not is_binary(authorization_header) or authorization_header == "",
       do: {:error, :forbidden}

  defp request_private_contact(url, authorization_header) do
    headers = [{~c"authorization", String.to_charlist(authorization_header)}]

    case :httpc.request(:get, {url, headers}, [connect_timeout: 2_000, timeout: 4_000],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"allowed" => true}} -> {:ok, %{allowed: true}}
          _ -> {:error, :forbidden}
        end

      {:ok, {{_, status, _}, _headers, _body}} when status in [401, 403, 404] ->
        {:error, :forbidden}

      _ ->
        {:error, :not_configured}
    end
  end
end
