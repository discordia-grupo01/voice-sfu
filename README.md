# Discordia Voice

Este directorio contiene los dos módulos del apartado de voz:

- `voice-sfu/` raíz: prototipo educativo de SFU propio con Go/Pion, RTP/RTCP y forwarding de audio.
- `signaling/`: módulo Elixir/Phoenix que autentica, autoriza salas y emite tokens de LiveKit.
- `livekit.yaml`: configuración local del media server LiveKit.

LiveKit es el media plane de la primera versión funcional. Phoenix es dueño del acceso a salas y entrega tokens. El Go SFU se conserva como prototipo alternativo bajo el perfil Docker `prototype`.

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

Phoenix escucha en `http://localhost:4000`, expone `GET /livez` y `GET /readyz`. El endpoint autenticado `POST /api/voice/token` recibe `{ "channel_id": "..." }`, valida el acceso en `servers` y devuelve un token para la sala derivada `voice:<channel_id>`.

### LiveKit

LiveKit escucha en `ws://localhost:7880` y publica media UDP en el rango `51000-51100`. El cliente debe conectarse usando un SDK de LiveKit con el token emitido por Phoenix.

### Docker Compose

```bash
cp .env.example .env
docker compose up --build
```

Esto levanta Phoenix, LiveKit, RabbitMQ y PostgreSQL. El Go SFU propio no se inicia por defecto; para probarlo se usa `docker compose --profile prototype up --build sfu`.

## Contrato actual

El mensaje de signaling Go usa `type`, `room_id`, `peer_id` y `data`. Los tipos actuales son `join`, `leave`, `offer`, `answer` y `candidate`; la forma exacta está en `internal/model/message.go`.

Los eventos publicados por el SFU son `voice.participant.joined`, `voice.participant.left` y `voice.channel.empty`. Sus payloads están en `internal/events/events-contract/voice.go`.

El contrato de acceso a LiveKit contiene `identity`, `room_name`, `token` y `url`. `room_name` no es entrada del cliente: Phoenix lo deriva del canal autorizado y firma el JWT con `LIVEKIT_API_KEY` y `LIVEKIT_API_SECRET`.

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
├── Dockerfile                imagen del SFU prototipo
├── livekit.yaml              configuración del media server local
└── signaling/Dockerfile      imagen del servicio de control
```

## Advertencias

- En desarrollo `VOICE_AUTHZ_MODE=allow_authenticated` permite cualquier usuario autenticado; producción debe conectar la autorización real de membresía del servicio de servidores.
- `SfuBridge` se conserva como prototipo de integración con el SFU Go, pero no participa del flujo LiveKit.
- LiveKit es el servidor de media; no enviar RTP por Phoenix, RabbitMQ ni el endpoint de tokens.
- El SFU Go mantiene las salas en memoria y no está preparado para múltiples réplicas.
- No mover lógica WebRTC, RTP o RTCP al módulo Phoenix.
