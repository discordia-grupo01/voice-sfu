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
  CREATE TABLE IF NOT EXISTS voice_outbox_events (
    event_id text PRIMARY KEY,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
  );
  CREATE INDEX IF NOT EXISTS voice_outbox_events_pending_idx
    ON voice_outbox_events (created_at) WHERE published_at IS NULL;
  CREATE TABLE IF NOT EXISTS voice_consumed_events (
    event_id text PRIMARY KEY,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    status text NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    error text,
    attempts integer NOT NULL DEFAULT 0
  );
  ALTER TABLE voice_consumed_events
    ADD COLUMN IF NOT EXISTS attempts integer NOT NULL DEFAULT 0;
  CREATE INDEX IF NOT EXISTS voice_consumed_events_status_idx
    ON voice_consumed_events (status, received_at);
  CREATE TABLE IF NOT EXISTS voice_event_versions (
    subject_type text NOT NULL,
    subject_id text NOT NULL,
    version bigint NOT NULL,
    PRIMARY KEY (subject_type, subject_id)
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

  def enqueue_outbox(event),
    do: GenServer.call(__MODULE__, {:enqueue_outbox, event}, 1_000)

  def pending_outbox(limit \\ 100),
    do: GenServer.call(__MODULE__, {:pending_outbox, limit}, 5_000)

  def mark_outbox_published(event_id),
    do: GenServer.call(__MODULE__, {:mark_outbox_published, event_id}, 5_000)

  def begin_consumption(event_id, event_type, payload),
    do: GenServer.call(__MODULE__, {:begin_consumption, event_id, event_type, payload}, 5_000)

  def complete_consumption(event_id, status, error \\ nil),
    do: GenServer.call(__MODULE__, {:complete_consumption, event_id, status, error}, 5_000)

  def next_consumption_attempt(event_id, error \\ nil),
    do: GenServer.call(__MODULE__, {:next_consumption_attempt, event_id, error}, 1_000)

  def newer_version(key, version),
    do: GenServer.call(__MODULE__, {:newer_version, key, version}, 1_000)

  def record_version(key, version),
    do: GenServer.call(__MODULE__, {:record_version, key, version}, 1_000)

  @impl true
  def init(_opts) do
    state = %{
      url:
        Application.get_env(:discordia_signaling, :voice_events, [])[:database_url] ||
          Application.get_env(:discordia_signaling, :replica, [])[:database_url] ||
          "postgres://discordia:discordia@localhost:5432/discordia_voice",
      conn: nil,
      ready: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: start_database_connect(state)

  @impl true
  def handle_info(:connect, %{conn: nil} = state), do: start_database_connect(state)

  def handle_info({:database_connected, conn}, state) do
    Process.monitor(conn)
    Logger.info("voice_replica_database_connected")
    {:noreply, %{state | conn: conn, ready: true}}
  end

  def handle_info({:database_connect_failed, reason}, state) do
    Logger.warning("voice_replica_database_connect_failed", reason: inspect(reason))
    Process.send_after(self(), :connect, 1_000)
    {:noreply, %{state | conn: nil, ready: false}}
  end

  def handle_info({:database_schema_failed, reason}, state) do
    Logger.warning("voice_replica_database_schema_failed", reason: inspect(reason))
    Process.send_after(self(), :connect, 1_000)
    {:noreply, %{state | conn: nil, ready: false}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("voice_replica_database_down", reason: inspect(reason))
    send(self(), :connect)
    {:noreply, Map.merge(state, %{conn: nil, ready: false})}
  end

  defp start_database_connect(state) do
    store = self()

    Task.start(fn ->
      case Postgrex.start_link(connection_options(state.url)) do
        {:ok, conn} ->
          case ensure_schema(conn) do
            :ok ->
              Process.unlink(conn)
              send(store, {:database_connected, conn})

            {:error, reason} ->
              close(conn)
              send(store, {:database_schema_failed, reason})
          end

        {:error, reason} ->
          send(store, {:database_connect_failed, reason})
      end
    end)

    {:noreply, Map.put(state, :ready, false)}
  end

  def handle_call(_message, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

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

  def handle_call({:enqueue_outbox, _event}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:enqueue_outbox, event}, _from, %{conn: conn} = state) do
    event_id = event["event_id"]
    event_type = event["event_type"]

    reply =
      if is_binary(event_id) and event_id != "" and is_binary(event_type) and event_type != "" do
        case Postgrex.query(
               conn,
               """
                 INSERT INTO voice_outbox_events (event_id, event_type, payload)
                 VALUES ($1, $2, $3::jsonb)
                 ON CONFLICT (event_id) DO NOTHING
               """,
               [event_id, event_type, event]
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :invalid_event}
      end

    {:reply, reply, state}
  end

  def handle_call({:pending_outbox, _limit}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:pending_outbox, limit}, _from, %{conn: conn} = state) do
    reply =
      Postgrex.query(
        conn,
        """
          SELECT event_id, event_type, payload::text
          FROM voice_outbox_events
          WHERE published_at IS NULL
          ORDER BY created_at, event_id
          LIMIT $1
        """,
        [limit]
      )

    result =
      case reply do
        {:ok, %{rows: rows}} ->
          {:ok,
           Enum.map(rows, fn [event_id, event_type, payload] ->
             %{event_id: event_id, event_type: event_type, payload: payload}
           end)}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:mark_outbox_published, _event_id}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:mark_outbox_published, event_id}, _from, %{conn: conn} = state) do
    reply =
      case Postgrex.query(
             conn,
             "UPDATE voice_outbox_events SET published_at = now() WHERE event_id = $1",
             [event_id]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:begin_consumption, _event_id, _event_type, _payload},
        _from,
        %{conn: nil} = state
      ),
      do: {:reply, {:error, :unavailable}, state}

  def handle_call(
        {:begin_consumption, event_id, event_type, payload},
        _from,
        %{conn: conn} = state
      ) do
    payload = audit_payload(payload)

    reply =
      case Postgrex.query(
             conn,
             """
               INSERT INTO voice_consumed_events (event_id, event_type, payload, status)
               VALUES ($1, $2, $3::jsonb, 'pending')
               ON CONFLICT (event_id) DO NOTHING
               RETURNING status
             """,
             [event_id, event_type, payload]
           ) do
        {:ok, %{num_rows: 1}} ->
          :new

        {:ok, %{num_rows: 0}} ->
          case Postgrex.query(
                 conn,
                 "SELECT status FROM voice_consumed_events WHERE event_id = $1",
                 [event_id]
               ) do
            {:ok, %{rows: [["processed"]]}} -> :processed
            {:ok, %{rows: [["invalid"]]}} -> :processed
            {:ok, %{rows: [["pending"]]}} -> :new
            {:ok, %{rows: [["failed"]]}} -> :new
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:complete_consumption, _event_id, _status, _error},
        _from,
        %{conn: nil} = state
      ),
      do: {:reply, {:error, :unavailable}, state}

  def handle_call({:complete_consumption, event_id, status, error}, _from, %{conn: conn} = state) do
    reply =
      case Postgrex.query(
             conn,
             """
               UPDATE voice_consumed_events
               SET status = $2, processed_at = CASE WHEN $2 = 'processed' THEN now() ELSE processed_at END,
                   error = $3
               WHERE event_id = $1
             """,
             [event_id, status, error]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:next_consumption_attempt, _event_id, _error}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:next_consumption_attempt, event_id, error}, _from, %{conn: conn} = state) do
    reply =
      case Postgrex.query(
             conn,
             """
               UPDATE voice_consumed_events
               SET attempts = attempts + 1, status = 'failed', error = $2
               WHERE event_id = $1
               RETURNING attempts
             """,
             [event_id, error]
           ) do
        {:ok, %{rows: [[attempts]]}} -> {:ok, attempts}
        {:ok, %{rows: []}} -> {:error, :unknown_event}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:newer_version, _key, _version}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:newer_version, key, version}, _from, %{conn: conn} = state) do
    reply =
      with {:ok, {subject_type, subject_id}} <- version_subject(key),
           {:ok, %{rows: rows}} <-
             Postgrex.query(
               conn,
               "SELECT version FROM voice_event_versions WHERE subject_type = $1 AND subject_id = $2",
               [subject_type, subject_id]
             ) do
        {:ok, rows == [] or version > hd(hd(rows))}
      end

    {:reply, reply, state}
  end

  def handle_call({:record_version, _key, _version}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:record_version, key, version}, _from, %{conn: conn} = state) do
    reply =
      with {:ok, {subject_type, subject_id}} <- version_subject(key),
           {:ok, _} <-
             Postgrex.query(
               conn,
               """
                 INSERT INTO voice_event_versions (subject_type, subject_id, version)
                 VALUES ($1, $2, $3)
                 ON CONFLICT (subject_type, subject_id)
                 DO UPDATE SET version = GREATEST(voice_event_versions.version, EXCLUDED.version)
               """,
               [subject_type, subject_id, version]
             ) do
        :ok
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
    query = URI.decode_query(uri.query || "")

    sslmode =
      System.get_env("DATABASE_SSLMODE") ||
        Map.get(query, "sslmode") ||
        default_sslmode(uri.host)

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
      pool_size: 1,
      prepare: :unnamed
    ]
    |> maybe_put(:username, username)
    |> maybe_put(:password, password)
    |> Keyword.merge(postgres_ssl(sslmode, uri.host))
    |> Keyword.merge(ip_family_options(uri.host))
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp default_sslmode(host) do
    if host in [nil, "localhost", "127.0.0.1", "::1"], do: "disable", else: "require"
  end

  defp postgres_ssl("disable", _host), do: []

  # "require" valida el certificado igual que "verify-full": cifrar sin validar
  # deja la conexion expuesta a un intermediario.
  defp postgres_ssl("require", host), do: postgres_ssl("verify-full", host)

  # Confia en el bundle del sistema y en las CA extra: DATABASE_CA_CERTFILE, o
  # priv/certs/*.crt (ahi va la CA de Supabase, que no esta en el bundle del sistema).
  defp postgres_ssl("verify-full", host) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get() ++ extra_ca_certs(),
        server_name_indication: String.to_charlist(host || "localhost"),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp postgres_ssl(_unknown, host), do: postgres_ssl(default_sslmode(host), host)

  defp extra_ca_certs do
    files =
      case System.get_env("DATABASE_CA_CERTFILE") do
        file when file not in [nil, ""] ->
          [file]

        _ ->
          :discordia_signaling
          |> Application.app_dir("priv/certs")
          |> Path.join("*.crt")
          |> Path.wildcard()
      end

    Enum.flat_map(files, fn file ->
      case File.read(file) do
        {:ok, pem} ->
          for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der

        {:error, _} ->
          []
      end
    end)
  end

  # db.<ref>.supabase.co solo tiene IPv6: sin :inet6 el connect falla con nxdomain.
  defp ip_family_options(nil), do: []

  defp ip_family_options(host) do
    charlist = String.to_charlist(host)

    cond do
      match?({:ok, _}, :inet.getaddr(charlist, :inet)) -> []
      match?({:ok, _}, :inet.getaddr(charlist, :inet6)) -> [socket_options: [:inet6]]
      true -> []
    end
  end

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
        [e["role_id"], e["server_id"], e["permissions"], e["is_everyone"]]
      )

  defp write(tx, :role_deleted, e),
    do: query_ok(tx, "DELETE FROM voice_replica_roles WHERE role_id=$1", [e["role_id"]])

  defp write(tx, :member_roles_updated, e),
    do:
      query_ok(
        tx,
        "INSERT INTO voice_replica_members (server_id,user_id,role_ids) VALUES ($1,$2,$3::jsonb) ON CONFLICT (server_id,user_id) DO UPDATE SET role_ids=EXCLUDED.role_ids",
        [e["server_id"], e["user_id"], e["role_ids"]]
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
                 override["allow"],
                 override["deny"]
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

  defp version_subject({:server, server_id}) when is_binary(server_id) and server_id != "",
    do: {:ok, {"server", server_id}}

  defp version_subject(user_id) when is_binary(user_id) and user_id != "",
    do: {:ok, {"user", user_id}}

  defp version_subject(_key), do: {:error, :invalid_subject}

  defp audit_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw_payload" => payload}
    end
  end

  defp audit_payload(payload), do: payload

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
