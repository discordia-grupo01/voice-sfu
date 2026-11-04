# Discordia Voice Signaling

Phoenix/Elixir service responsible for voice rooms, channel membership, and signaling transport. The Go module in the parent directory owns WebRTC, RTP/RTCP, and media forwarding.

## Local development

```bash
mix deps.get
mix phx.server
```

The service listens on `http://localhost:4000`. Health check: `GET /livez`. Phoenix channels use `/socket` and the `voice:*` and `voice_server:*` topics.

Private one-to-one calls use `POST /api/voice/calls` with
`recipient_id` and `conversation_id`. Signaling asks Messaging to authorize
that direct conversation, including both-direction block checks, before
creating a `private-call:<call_id>` LiveKit room. The recipient can accept,
reject, or the participants can finish the call through
`/api/voice/calls/:id/{accept,reject,finish}`. Real-time transitions are
delivered on the authenticated `voice_user:<user_id>` socket topic; the
`voice.private_call` event is also published for Notifications push delivery.
The accept response (recipient) and the `private_call_accepted` event (caller)
include the LiveKit `token` and `url` each participant needs to join the room.
`POST /api/voice/calls/:id/screen-token` gives a participant of an active call
the screen-only companion token (`<user_id>:screen`) the Android app uses to
share its screen.

## Current boundary

`DiscordiaSignaling.Voice.SfuBridge` is the integration seam for the internal transport to the Go SFU. It intentionally returns `:not_configured` until the protocol, authentication, framing, retries, and backpressure policy are defined. Do not move WebRTC or RTP logic into this application.

## Environment

- `PORT`: HTTP port, defaults to `4000`.
- `SECRET_KEY_BASE`: required when `MIX_ENV=prod`.
- `SERVERS_URL`: base URL of the servers service used for voice authorization.
- `MESSAGING_URL`: base URL of Messaging used to validate direct-call access and blocks.
- `RABBITMQ_URL`: broker URL for servers events (mute, channel access revoked, channel and server deleted); when empty, the consumer is disabled.
- `EVENTS_EXCHANGE`: RabbitMQ topic exchange, defaults to `discordia.events`.
- `VOICE_EVENTS_QUEUE`: durable queue for this signaling instance, defaults to `voice.signaling`.
- `VOICE_INSTANCE_ID`: stable identifier used to suffix per-instance RabbitMQ
  queues. Defaults to `FLY_ALLOC_ID`, `HOSTNAME` or `default`; set it explicitly
  when running multiple local replicas. Do not reuse the same value across
  simultaneously running replicas.
- `ADMIN_EVENTS_HMAC_SECRET`: secret shared with admin to verify the signature of `admin.user_suspended`. If empty, the suspension consumer does not start (an error is logged) and the rest of the service keeps running.
- `VOICE_AUTHZ_MODE`: `servers_api` for membership and `VIEW_CHANNELS` checks; `allow_authenticated` is local-only.
- `PHOENIX_CHECK_ORIGINS`: comma-separated browser origins allowed to open
  Phoenix sockets. Local defaults are `http://localhost:3000` and
  `http://127.0.0.1:3000`; production must include the exact HTTPS origin of
  the deployed web client.

## CI/CD con Fly.io

El workflow de `voice-sfu` despliega este servicio desde `signaling/`:

- `develop` usa `fly.staging.toml` y el secret `FLY_API_TOKEN_STAGING`.
- `main` usa `fly.production.toml` y el secret `FLY_API_TOKEN_PRODUCTION`.

Antes del primer despliegue, crea las aplicaciones `discordia-signaling-staging` y
`discordia-signaling-production`, y configura en cada una los secrets `SECRET_KEY_BASE`,
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL`, `SERVERS_URL`, `RABBITMQ_URL` y
`ADMIN_EVENTS_HMAC_SECRET` (mismo valor que admin; se carga con `fly secrets`).
Los manifests solo contienen configuración no sensible.

The production manifest allows `https://discordia-g1.vercel.app` to open the
voice socket. If the Vercel deployment uses another custom domain, update
`PHOENIX_CHECK_ORIGINS` before deploying. Do not use `check_origin: false`.

`POST /api/voice/token` accepts only `{ "channel_id": "..." }`. Phoenix derives
the LiveKit room name as `voice:<channel_id>` and forwards the validated JWT to
`GET /v1/channels/{channelId}/voice-access` in `servers`. The authorization
response supplies the user's replicated public profile name, which Phoenix
includes in the LiveKit token `name` claim.

The browser presence socket uses `POST /api/voice/socket-ticket` first. This
authenticated endpoint issues a 30-second ticket signed with `JWT_SECRET`;
Phoenix validates that ticket in the WebSocket handshake. The gateway JWT
plugin is intentionally applied to the HTTP routes only, not to
`GET /voice/socket`, because browsers cannot add the `Authorization` header to
the Phoenix WebSocket upgrade. The ticket keeps the access JWT and refresh
token inside the web BFF.

`GET /api/voice/participants?server_id=...` returns the initial participant
snapshot grouped by visible voice channel. After joining
`voice_server:<server_id>` through `/voice/socket`, presence changes are pushed
as `voice.participant_joined` and `voice.participant_left`. In `servers_api` mode the request
is authorized through `GET /v1/servers/{serverId}/membership` in `servers` (a
yes/no check, 403 for a non-member) before the snapshot is returned. The call
has a 2 s connect and 4 s total timeout; if `servers` fails or does not answer,
the endpoint answers `503 voice_unavailable`, not `403`. A confirmed membership
is kept in memory for 30 s per user and server, so snapshot clients do not hit
`servers` on every request; refusals and failures are never kept. This needs a
`servers` version that has the membership endpoint: deploy it first. Presence
changes are also pushed to joined Phoenix voice topics and published as
`voice.participant_joined` / `voice.participant_left`. The public WebSocket
endpoint is `/voice/socket` (the legacy local `/socket` endpoint remains).

Each signaling replica consumes presence events through its own queue and
replays them into its local session registry. Presence snapshots are applied
only when their `occurred_at` is newer than the local snapshot, so duplicate
and out-of-order deliveries do not overwrite newer state. Control events use
the same per-instance queue strategy; PubSub remains a local delivery
optimization and is not the replication mechanism.

When a node starts, `VoicePresenceReconciler` asks LiveKit for the current
rooms and participants and rebuilds the local snapshot. It retries while
LiveKit is unavailable and repeats the reconciliation periodically, removing
participants that are no longer connected. Someone registered in the last
15 s (`reconcile_grace_ms`) is neither removed nor moved by it: they may not
have reached their LiveKit room yet, or LiveKit may still list them in the room
they left. The registry also remembers each room's server, so a participant the
reconciliation adds back keeps showing in that server's snapshot. LiveKit does not expose the
application `server_id` in this query; an existing local `server_id` is
preserved, while a newly reconstructed participant is visible only in
unfiltered snapshots until the next authenticated access flow supplies the
server context.

`DiscordiaSignaling.Events.MutingConsumer` binds `servers.member_muted`,
`servers.member_unmuted`, `servers.channel_access_revoked`,
`servers.channel_deleted` and `servers.server_deleted`. Mute events toggle
`canPublish` in LiveKit; an access revocation removes each listed user from
`voice:<channel_id>` (this is how kick, ban and leave end an active call);
channel and server deletions close the affected rooms with `DeleteRoom`.
LiveKit errors other than `not_found` requeue the message.

`DiscordiaSignaling.Events.SuspensionConsumer` binds `admin.user_suspended` on
its own per-replica queue. It verifies the HMAC signature
(`DiscordiaSignaling.Events.AdminSignature`), ignores versions not newer than
the last one seen for the user (`SuspensionVersions`, in memory only) and
removes the user from their active room through
`VoiceSessionRegistry.leave/2`, the same call used for
`servers.channel_access_revoked`. A user who is not in voice, or whom LiveKit
no longer has, is a success; LiveKit errors requeue the message; invalid
signatures and malformed payloads are acked and discarded. Blocking *entry* is
not done here: `POST /api/voice/token` relies on `voice-access` in `servers`,
which answers `403` for a suspended user (with `VOICE_AUTHZ_MODE=allow_authenticated`,
local only, a suspended user could still get a token).

## Tests y cobertura

```bash
mix test --cover
```

La suite esta organizada en `test/discordia_signaling/voice` para dominio y
`test/discordia_signaling_web` para Plug, controllers, Channels y rutas. El
comando muestra el porcentaje por modulo y falla si la cobertura total baja de
70%, configurado en `mix.exs`.

La prueba de integración de RabbitMQ está en
`test/integration/voice_presence_rabbitmq_test.exs`. Se ejecuta sólo cuando
`RABBITMQ_URL` está definido; publica un evento real en `discordia.events`,
lo consume otra conexión y verifica la actualización local para join y leave.
Para ejecutarla localmente:

```bash
$env:RABBITMQ_URL = "amqp://guest:guest@localhost:5672"
mix test test/integration/voice_presence_rabbitmq_test.exs
```

La de suspensiones está en `test/integration/voice_suspension_rabbitmq_test.exs` y se
ejecuta igual: publica un `admin.user_suspended` falsificado (no expulsa) y uno firmado
(expulsa).

Las pruebas marcadas como `integration` se excluyen de `mix test` por defecto.
Para incluirlas explícitamente se usa:

```bash
mix test --include integration test/integration/voice_presence_rabbitmq_test.exs
```
