defmodule DiscordiaSignaling.Voice.ReplicaStore do
  use GenServer
  require Logger

  @schema """
  CREATE TABLE IF NOT EXISTS voice_replica_clocks (
    key text PRIMARY KEY,
    at timestamptz NOT NULL
  );
  CREATE TABLE IF NOT EXISTS voice_replica_channels (
    channel_id text PRIMARY KEY,
    server_id text NOT NULL,
    kind text NOT NULL
  );
  CREATE TABLE IF NOT EXISTS voice_replica_roles (
    role_id text PRIMARY KEY,
    server_id text NOT NULL,
    permissions jsonb NOT NULL,
    is_everyone boolean NOT NULL
  );
  CREATE TABLE IF NOT EXISTS voice_replica_members (
    server_id text NOT NULL,
    user_id text NOT NULL,
    role_ids jsonb NOT NULL,
    PRIMARY KEY (server_id, user_id)
  );
  CREATE TABLE IF NOT EXISTS voice_replica_overrides (
    channel_id text NOT NULL,
    role_id text NOT NULL,
    allow_permissions jsonb NOT NULL,
    deny_permissions jsonb NOT NULL,
    PRIMARY KEY (channel_id, role_id)
  );
  CREATE TABLE IF NOT EXISTS voice_replica_owners (
    server_id text PRIMARY KEY,
    owner_id text NOT NULL
  );
  CREATE TABLE IF NOT EXISTS voice_replica_mutes (
    server_id text NOT NULL,
    user_id text NOT NULL,
    until_at timestamptz,
    PRIMARY KEY (server_id, user_id)
  );
  CREATE TABLE IF NOT EXISTS voice_replica_profiles (
    user_id text PRIMARY KEY,
    name text NOT NULL,
    version bigint NOT NULL
  );
  """

  @keys %{
    "servers.role_updated" => :role_updated,
    "servers.role_deleted" => :role_deleted,
    "servers.member_roles_updated" => :member_roles_updated,
    "servers.member_left" => :member_left,
    "servers.channel_overrides_updated" => :channel_overrides_updated,
    "servers.owner_updated" => :owner_updated,
    "servers.channel_created" => :channel_created,
    "servers.channel_deleted" => :channel_deleted,
    "servers.server_deleted" => :server_deleted,
    "servers.member_muted" => :member_muted,
    "servers.member_unmuted" => :member_unmuted,
    "users.profile_updated" => :profile_updated
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def apply_event(routing_key, event),
    do: GenServer.call(__MODULE__, {:apply, routing_key, event}, 10_000)

  def authorize(channel_id, user_id),
    do: GenServer.call(__MODULE__, {:authorize, channel_id, user_id}, 5_000)

  def ping, do: GenServer.call(__MODULE__, :ping, 2_000)

  @impl true
  def init(_opts) do
    state = %{
      url:
        Application.get_env(:discordia_signaling, :replica, [])[:database_url] ||
          "postgres://discordia:discordia@localhost:5432/discordia_voice",
      conn: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, %{conn: nil} = state) do
    case Postgrex.start_link(connection_options(state.url)) do
      {:ok, conn} ->
        case ensure_schema(conn) do
          :ok ->
            Process.monitor(conn)
            Logger.info("voice_replica_database_connected")
            {:noreply, %{state | conn: conn}}

          {:error, reason} ->
            close(conn)
            Logger.warning("voice_replica_database_schema_failed", reason: inspect(reason))
            Process.send_after(self(), :connect, 1_000)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("voice_replica_database_connect_failed", reason: inspect(reason))
        Process.send_after(self(), :connect, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_replica_database_down", reason: inspect(reason))
    send(self(), :connect)
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_call(:ping, _from, %{conn: nil} = state), do: {:reply, {:error, :unavailable}, state}

  def handle_call(:ping, _from, %{conn: conn} = state) do
    reply =
      case Postgrex.query(conn, "SELECT 1", []) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:apply, _routing_key, _event}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:apply, routing_key, event}, _from, %{conn: conn} = state) do
    reply = Postgrex.transaction(conn, fn tx -> apply_in_transaction(tx, routing_key, event) end)
    {:reply, reply, state}
  end

  def handle_call({:authorize, _channel_id, _user_id}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:authorize, channel_id, user_id}, _from, %{conn: conn} = state) do
    reply = authorize_query(conn, channel_id, user_id)
    {:reply, reply, state}
  end

  defp ensure_schema(conn) do
    Enum.reduce_while(String.split(@schema, ";", trim: true), :ok, fn statement, :ok ->
      case Postgrex.query(conn, statement, []) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp connection_options(url) do
    uri = URI.parse(url)

    {username, password} =
      case uri.userinfo do
        nil ->
          {nil, nil}

        value ->
          case String.split(value, ":", parts: 2) do
            [user, pass] -> {URI.decode(user), URI.decode(pass)}
            [user] -> {URI.decode(user), nil}
          end
      end

    [
      hostname: String.to_charlist(uri.host || "localhost"),
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/discordia_voice", "/"),
      pool_size: 1
    ]
    |> maybe_put(:username, username)
    |> maybe_put(:password, password)
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp apply_in_transaction(tx, routing_key, event) do
    try do
      with {:ok, kind} <- Map.fetch(@keys, routing_key),
           {:ok, occurred_at, _offset} <- DateTime.from_iso8601(event["occurred_at"]),
           true <- is_binary(event["event_id"]) and event["event_id"] != "",
           :ok <- clock(tx, clock_key(kind, event), occurred_at),
           :ok <- write(tx, kind, event) do
        :applied
      else
        :stale -> :stale
        {:error, reason} -> {:error, reason}
        _ -> :invalid
      end
    rescue
      _error -> :invalid
    end
  end

  defp clock(tx, key, at) do
    case Postgrex.query(
           tx,
           """
             INSERT INTO voice_replica_clocks (key, at) VALUES ($1, $2)
             ON CONFLICT (key) DO UPDATE SET at = EXCLUDED.at
             WHERE voice_replica_clocks.at < EXCLUDED.at
             RETURNING 1
           """,
           [key, at]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> :stale
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(tx, :role_updated, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_roles (role_id, server_id, permissions, is_everyone) VALUES ($1,$2,$3::jsonb,$4) ON CONFLICT (role_id) DO UPDATE SET server_id=EXCLUDED.server_id, permissions=EXCLUDED.permissions, is_everyone=EXCLUDED.is_everyone",
        [e["role_id"], e["server_id"], Jason.encode!(e["permissions"]), e["is_everyone"]]
      )

  defp write(tx, :role_deleted, e),
    do: query_ok(tx, "DELETE FROM voice_replica_roles WHERE role_id=$1", [e["role_id"]])

  defp write(tx, :member_roles_updated, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_members (server_id,user_id,role_ids) VALUES ($1,$2,$3::jsonb) ON CONFLICT (server_id,user_id) DO UPDATE SET role_ids=EXCLUDED.role_ids",
        [e["server_id"], e["user_id"], Jason.encode!(e["role_ids"])]
      )

  defp write(tx, :member_left, e),
    do:
      query_ok(tx, "DELETE FROM voice_replica_members WHERE server_id=$1 AND user_id=$2", [
        e["server_id"],
        e["user_id"]
      ])

  defp write(tx, :owner_updated, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_owners (server_id,owner_id) VALUES ($1,$2) ON CONFLICT (server_id) DO UPDATE SET owner_id=EXCLUDED.owner_id",
        [e["server_id"], e["owner_id"]]
      )

  defp write(tx, :channel_created, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_channels (channel_id,server_id,kind) VALUES ($1,$2,$3) ON CONFLICT (channel_id) DO UPDATE SET server_id=EXCLUDED.server_id, kind=EXCLUDED.kind",
        [e["channel_id"], e["server_id"], e["kind"]]
      )

  defp write(tx, :channel_deleted, e),
    do:
      query_ok(tx, "DELETE FROM voice_replica_channels WHERE channel_id=$1", [e["channel_id"]])
      |> delete_overrides(tx, e["channel_id"])

  defp write(tx, :server_deleted, e) do
    {:ok, at, _offset} = DateTime.from_iso8601(e["occurred_at"])

    query_ok(
      tx,
      """
        INSERT INTO voice_replica_clocks (key, at)
        SELECT key, $2 FROM (
          SELECT 'channel:' || channel_id AS key FROM voice_replica_channels WHERE server_id = $1
          UNION ALL SELECT 'overrides:' || channel_id FROM voice_replica_channels WHERE server_id = $1
          UNION ALL SELECT 'role:' || role_id FROM voice_replica_roles WHERE server_id = $1
          UNION ALL SELECT 'member:' || server_id || ':' || user_id FROM voice_replica_members WHERE server_id = $1
          UNION ALL SELECT 'owner:' || server_id FROM voice_replica_owners WHERE server_id = $1
        ) entities
        ON CONFLICT (key) DO UPDATE SET at = GREATEST(voice_replica_clocks.at, EXCLUDED.at)
      """,
      [e["server_id"], at]
    )

    query_ok(tx, "DELETE FROM voice_replica_channels WHERE server_id=$1", [e["server_id"]])
    query_ok(tx, "DELETE FROM voice_replica_members WHERE server_id=$1", [e["server_id"]])
    query_ok(tx, "DELETE FROM voice_replica_roles WHERE server_id=$1", [e["server_id"]])
    query_ok(tx, "DELETE FROM voice_replica_owners WHERE server_id=$1", [e["server_id"]])
    :ok
  end

  defp write(tx, :channel_overrides_updated, e) do
    with :ok <-
           query_ok(tx, "DELETE FROM voice_replica_overrides WHERE channel_id=$1", [
             e["channel_id"]
           ]) do
      Enum.reduce_while(e["overrides"], :ok, fn override, :ok ->
        case query_ok(
               tx,
               "INSERT INTO voice_replica_overrides VALUES ($1,$2,$3::jsonb,$4::jsonb)",
               [
                 e["channel_id"],
                 override["role_id"],
                 Jason.encode!(override["allow"]),
                 Jason.encode!(override["deny"])
               ]
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp write(tx, :member_muted, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_mutes VALUES ($1,$2,$3) ON CONFLICT (server_id,user_id) DO UPDATE SET until_at=EXCLUDED.until_at",
        [e["server_id"], e["user_id"], e["until_at"]]
      )

  defp write(tx, :member_unmuted, e),
    do:
      query_ok(tx, "DELETE FROM voice_replica_mutes WHERE server_id=$1 AND user_id=$2", [
        e["server_id"],
        e["user_id"]
      ])

  defp write(tx, :profile_updated, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_profiles VALUES ($1,$2,$3) ON CONFLICT (user_id) DO UPDATE SET name=EXCLUDED.name, version=EXCLUDED.version WHERE voice_replica_profiles.version < EXCLUDED.version",
        [e["user_id"], e["name"], e["version"]]
      )

  defp delete_overrides(:ok, tx, channel_id),
    do: query_ok(tx, "DELETE FROM voice_replica_overrides WHERE channel_id=$1", [channel_id])

  defp delete_overrides(error, _tx, _channel_id), do: error

  defp query_ok(tx, sql, params) do
    case Postgrex.query(tx, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_query(conn, channel_id, user_id) do
    sql = """
    SELECT c.server_id, c.kind, o.owner_id, m.role_ids,
      COALESCE((SELECT jsonb_object_agg(role_id, jsonb_build_object('permissions', permissions, 'is_everyone', is_everyone)) FROM voice_replica_roles WHERE server_id=c.server_id), '{}'::jsonb),
      COALESCE((SELECT jsonb_object_agg(role_id, jsonb_build_object('allow', allow_permissions, 'deny', deny_permissions)) FROM voice_replica_overrides WHERE channel_id=c.channel_id), '{}'::jsonb),
      (SELECT until_at > now() FROM voice_replica_mutes WHERE server_id=c.server_id AND user_id=$2),
      (SELECT name FROM voice_replica_profiles WHERE user_id=$2)
    FROM voice_replica_channels c
    LEFT JOIN voice_replica_owners o ON o.server_id=c.server_id
    LEFT JOIN voice_replica_members m ON m.server_id=c.server_id AND m.user_id=$2
    WHERE c.channel_id=$1
    """

    case Postgrex.query(conn, sql, [channel_id, user_id]) do
      {:ok, %{rows: [row]}} -> {:ok, row}
      {:ok, %{rows: []}} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clock_key(:role_updated, e), do: "role:" <> e["role_id"]
  defp clock_key(:role_deleted, e), do: "role:" <> e["role_id"]
  defp clock_key(:member_roles_updated, e), do: "member:" <> e["server_id"] <> ":" <> e["user_id"]
  defp clock_key(:member_left, e), do: "member:" <> e["server_id"] <> ":" <> e["user_id"]
  defp clock_key(:channel_overrides_updated, e), do: "overrides:" <> e["channel_id"]
  defp clock_key(:owner_updated, e), do: "owner:" <> e["server_id"]
  defp clock_key(:channel_created, e), do: "channel:" <> e["channel_id"]
  defp clock_key(:channel_deleted, e), do: "channel:" <> e["channel_id"]
  defp clock_key(:server_deleted, e), do: "server:" <> e["server_id"]
  defp clock_key(:member_muted, e), do: "mute:" <> e["server_id"] <> ":" <> e["user_id"]
  defp clock_key(:member_unmuted, e), do: "mute:" <> e["server_id"] <> ":" <> e["user_id"]
  defp clock_key(:profile_updated, e), do: "profile:" <> e["user_id"]

  defp close(conn) do
    GenServer.stop(conn)
  catch
    :exit, _ -> :ok
  end
end
