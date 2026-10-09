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
