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
- `RABBITMQ_URL`: broker URL for moderation events; when empty, the consumer is disabled.
- `EVENTS_EXCHANGE`: RabbitMQ topic exchange, defaults to `discordia.events`.
- `VOICE_EVENTS_QUEUE`: durable queue for this signaling instance, defaults to `voice.signaling`.
- `VOICE_AUTHZ_MODE`: `servers_api` for membership and `VIEW_CHANNELS` checks; `allow_authenticated` is local-only.

`POST /api/voice/token` accepts only `{ "channel_id": "..." }`. Phoenix derives
the LiveKit room name as `voice:<channel_id>` and forwards the validated JWT to
`GET /v1/channels/{channelId}/voice-access` in `servers`. The authorization
response supplies the user's replicated public profile name, which Phoenix
includes in the LiveKit token `name` claim.

## Tests y cobertura

```bash
mix test --cover
```

La suite esta organizada en `test/discordia_signaling/voice` para dominio y
`test/discordia_signaling_web` para Plug, controllers, Channels y rutas. El
comando muestra el porcentaje por modulo y falla si la cobertura total baja de
70%, configurado en `mix.exs`.
