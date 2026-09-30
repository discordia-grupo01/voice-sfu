# Discordia Voice

Este directorio contiene los dos módulos del apartado de voz:

- `voice-sfu/` raíz: módulo Go que ejecuta el SFU con Pion WebRTC, RTP/RTCP y forwarding de audio.
- `signaling/`: módulo Elixir/Phoenix que expone salas, canales y el transporte de signaling.

Phoenix es dueño del estado de signaling. Go es dueño de las conexiones WebRTC y del media plane. La comunicación interna entre ambos está representada por `DiscordiaSignaling.Voice.SfuBridge`, pero todavía no tiene transporte implementado.

## Desarrollo local

### Go SFU

Desde este directorio:

```bash
go mod download
go test ./... -cover
go run ./cmd/api
```

El SFU escucha HTTP/WebSocket en `8080` y media UDP en `50000`. `PUBLIC_IP` debe ser una dirección alcanzable por los clientes WebRTC.

### Phoenix signaling

Desde `signaling/`:

```bash
mix deps.get
mix phx.server
```

Phoenix escucha en `http://localhost:4000`, expone `GET /livez` y usa `/socket` con topics `voice:*`.

### Docker Compose

```bash
cp .env.example .env
docker compose up --build
```

Esto levanta ambos módulos, RabbitMQ y PostgreSQL. PostgreSQL está reservado para la evolución del estado persistente; el SFU actual usa memoria y `/readyz` todavía no comprueba una base de datos.

## Contrato actual

El mensaje de signaling Go usa `type`, `room_id`, `peer_id` y `data`. Los tipos actuales son `join`, `leave`, `offer`, `answer` y `candidate`; la forma exacta está en `internal/model/message.go`.

Los eventos publicados por el SFU son `voice.participant.joined`, `voice.participant.left` y `voice.channel.empty`. Sus payloads están en `internal/events/events-contract/voice.go`.

## Estructura

```text
voice-sfu/
├── cmd/api/                 entrypoint del SFU Go
├── internal/                handler, servicio WebRTC, repositorio y eventos
├── migrations/              futuras migraciones del servicio
├── signaling/
│   ├── config/               configuración Phoenix
│   └── lib/                  OTP application, Endpoint, Socket y Channel
├── docker-compose.yml
├── Dockerfile                imagen del SFU
└── signaling/Dockerfile      imagen del signaling
```

## Advertencias

- El signaling Phoenix no autentica usuarios todavía.
- `SfuBridge` devuelve `:not_configured`; antes de elegir gRPC o TCP hay que definir autenticación interna, framing, retries y backpressure.
- El SFU mantiene las salas en memoria y no está preparado para múltiples réplicas.
- No mover lógica WebRTC, RTP o RTCP al módulo Phoenix.
