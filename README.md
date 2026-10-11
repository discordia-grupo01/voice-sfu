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

Phoenix consume del exchange `discordia.events` (cola `VOICE_EVENTS_QUEUE`, por defecto `voice.signaling`) estos eventos de `servers`:

- `servers.member_muted` / `servers.member_unmuted`: quita o devuelve el permiso de publicar audio al participante en su sala activa.
- `servers.channel_access_revoked`: saca de la sala `voice:<channel_id>` a los `user_ids` que perdieron `VIEW_CHANNELS` en ese canal (overrides o cambios de roles, transferencia de propiedad, expulsión, baneo o abandono del servidor). Así es como se corta la llamada al expulsar, banear o cuando el miembro abandona el servidor. Si el usuario está en otra sala o no está en voz, no pasa nada.
- `servers.channel_deleted`: cierra la sala `voice:<channel_id>` con `DeleteRoom` de LiveKit, que desconecta a todos sus participantes.
- `servers.server_deleted`: cierra la sala de cada canal de `channel_ids`.

Una sala o participante que LiveKit ya no tiene cuenta como éxito. Si LiveKit no responde, el mensaje se devuelve a la cola (nack con requeue) y se reintenta entero; repetir la salida o el cierre es idempotente. Los payloads inválidos se descartan con ack. Los contratos están en `discordia-events_contract` (`channels/events.go`, `servers/events.go`).

Cada réplica de signaling usa una cola RabbitMQ propia, derivada de
`VOICE_EVENTS_QUEUE` y `VOICE_INSTANCE_ID`, para que todas las réplicas reciban
los eventos de control y presencia. Los eventos
`voice.participant_joined`/`voice.participant_left` se reaplican de forma
idempotente en el registro local usando `occurred_at`; PubSub sólo distribuye
actualizaciones dentro del nodo. Esto replica el estado de signaling, no el
media plane: LiveKit continúa siendo responsable de WebRTC, RTP y RTCP.

Al arrancar, una réplica no depende de eventos históricos: consulta a LiveKit
con `ListRooms` y `ListParticipants`, reconstruye su registro local y repite la
reconciliación periódicamente. Si LiveKit está caído, conserva el proceso vivo,
registra el error y reintenta. Esto recupera los participantes conectados en
ese momento; no recupera llamadas ya terminadas, porque no forman parte del
estado activo.

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
