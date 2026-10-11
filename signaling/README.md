# Discordia Voice Signaling

Phoenix/Elixir service responsible for voice rooms, channel membership, and signaling transport. The Go module in the parent directory owns WebRTC, RTP/RTCP, and media forwarding.

## Local development

```bash
mix deps.get
mix phx.server
```

The service listens on `http://localhost:4000`. Health check: `GET /livez`. Phoenix channels use `/socket` and the `voice:*` topic.

## Current boundary

`DiscordiaSignaling.Voice.SfuBridge` is the integration seam for the internal transport to the Go SFU. It intentionally returns `:not_configured` until the protocol, authentication, framing, retries, and backpressure policy are defined. Do not move WebRTC or RTP logic into this application.

## Environment

- `PORT`: HTTP port, defaults to `4000`.
- `SECRET_KEY_BASE`: required when `MIX_ENV=prod`.
- `SERVERS_URL`: base URL of the servers service used for voice authorization.
- `RABBITMQ_URL`: broker URL for servers events (mute, channel access revoked, channel and server deleted); when empty, the consumer is disabled.
- `EVENTS_EXCHANGE`: RabbitMQ topic exchange, defaults to `discordia.events`.
- `VOICE_EVENTS_QUEUE`: durable queue for this signaling instance, defaults to `voice.signaling`.
- `VOICE_INSTANCE_ID`: stable identifier used to suffix per-instance RabbitMQ
  queues. Defaults to `FLY_ALLOC_ID`, `HOSTNAME` or `default`; set it explicitly
  when running multiple local replicas. Do not reuse the same value across
  simultaneously running replicas.
- `VOICE_AUTHZ_MODE`: `servers_api` for membership and `VIEW_CHANNELS` checks; `allow_authenticated` is local-only.

## CI/CD con Fly.io

El workflow de `voice-sfu` despliega este servicio desde `signaling/`:

- `develop` usa `fly.staging.toml` y el secret `FLY_API_TOKEN_STAGING`.
- `main` usa `fly.production.toml` y el secret `FLY_API_TOKEN_PRODUCTION`.

Antes del primer despliegue, crea las aplicaciones `discordia-signaling-staging` y
`discordia-signaling-production`, y configura en cada una los secrets `SECRET_KEY_BASE`,
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_URL`, `SERVERS_URL` y `RABBITMQ_URL`.
Los manifests solo contienen configuración no sensible.

`POST /api/voice/token` accepts only `{ "channel_id": "..." }`. Phoenix derives
the LiveKit room name as `voice:<channel_id>` and forwards the validated JWT to
`GET /v1/channels/{channelId}/voice-access` in `servers`. The authorization
response supplies the user's replicated public profile name, which Phoenix
includes in the LiveKit token `name` claim.

`GET /api/voice/participants?server_id=...` returns the current participant
snapshot grouped by visible voice channel. In `servers_api` mode the request
is authorized through `servers` before the snapshot is returned. Presence
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
participants that are no longer connected. LiveKit does not expose the
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

Las pruebas marcadas como `integration` se excluyen de `mix test` por defecto.
Para incluirlas explícitamente se usa:

```bash
mix test --include integration test/integration/voice_presence_rabbitmq_test.exs
```
