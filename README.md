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

`POST /api/voice/screen-token` (mismo body) es para compartir la pantalla desde el APK de Android: la llamada de mobile corre en un WebView que no puede capturar la pantalla, así que la app entra a la misma sala una segunda vez con la identidad `<user_id>:screen`, que solo puede publicar la pantalla y no se suscribe a nada. Solo se emite si el usuario ya está en esa sala (`409 voice_not_in_channel`) y no está silenciado por un moderador (`403 voice_screen_share_forbidden`). Ese acompañante no cuenta como participante (no aparece en la presencia), y signaling lo saca junto con su dueño al salir, cambiar de canal, perder el acceso o ser silenciado.

### LiveKit

LiveKit escucha en `ws://localhost:7880` y publica media UDP en el rango `51000-51100`. El cliente debe conectarse usando un SDK de LiveKit con el token emitido por Phoenix.

Las llamadas privadas 1 a 1 usan `POST /api/voice/calls` con el `recipient_id` y
el `conversation_id` de la conversación directa. Phoenix valida esa conversación
contra Messaging, incluyendo bloqueos en ambos sentidos, y crea una sala
`private-call:<call_id>`. La aceptación, el rechazo y la finalización se
gestionan en `/api/voice/calls/:id/{accept,reject,finish}`. Las transiciones
llegan al topic autenticado `voice_user:<user_id>` y se publica
`voice.private_call` para Notifications. Para compartir la pantalla desde el
APK durante una llamada privada, `POST /api/voice/calls/:id/screen-token` da el
mismo token de acompañante `<user_id>:screen`; solo lo reciben los dos
participantes y con la llamada ya atendida (`403 voice_call_forbidden`,
`404 call_not_found`, `409 invalid_call_state`).

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

Además consume `admin.user_suspended` (`Events.SuspensionConsumer`, cola propia por réplica, sufijo `suspensions`) para sacar de su sala a un usuario suspendido a nivel plataforma:

- Verifica la firma `HMAC-SHA256(ADMIN_EVENTS_HMAC_SECRET, routing_key 
 event_id 
 user_id 
 version 
 occurred_at)` en hexadecimal minúsculas, con el `occurred_at` tal cual llegó. Un evento sin firma o con firma inválida se descarta con ack y un warning, sin tocar nada.
- Si la `version` es mayor a la última vista para ese usuario (registro en memoria, se pierde al reiniciar), saca al usuario de su sala activa con la misma operación que `servers.channel_access_revoked`. Si no está en voz o LiveKit ya no lo tiene, es éxito; si LiveKit no responde, se reencola.
- `admin.user_reactivated` no requiere nada en voz.
- Si `ADMIN_EVENTS_HMAC_SECRET` está vacío, este consumidor no arranca (se loguea el error) y el resto del servicio sigue.

La misma cola recibe también la moderación de **servidores** (HU #69), con la misma firma pero con `server_id` como sujeto firmado en lugar de `user_id`:

- `admin.server_suspended`: si su `version` es mayor a la última vista para ese servidor (en memoria, como las de usuarios), olvida las membresías de ese servidor en `MembershipCache`, cierra con `DeleteRoom` todas las salas que este nodo conoce para el servidor (`VoiceSessionRegistry.rooms_of_server/1`, el evento no trae canales) y registra la versión. Es el mismo camino que `servers.server_deleted`, así que se corta también a quien comparte pantalla. Si LiveKit no responde se reencola sin registrar la versión.
- `admin.server_reactivated`: no abre ni cierra nada; solo registra la versión, para que una suspensión más vieja que llegue tarde no vuelva a sacar a quien ya reingresó.
- Se descartan con ack, sin tocar nada, los eventos con firma ausente o inválida, JSON roto, `server_id` vacío o `version < 1`.
- `admin.server_deletion_requested` no se consume acá: `servers` lo ejecuta y publica `servers.server_deleted`, que voz ya procesa.
- La **entrada** a voz de un servidor suspendido la bloquea `voice-access` de `servers` con `403` (voz lo traduce a `voice_forbidden`, igual que el `403` de `/membership` en la presencia). Orden de despliegue: voz tiene que estar desplegada **antes** que admin; si no, un `server_suspended` publicado antes de que exista el binding no llega y se recupera con `make republish-suspensions` en admin.

La **entrada** de un suspendido a voz no se decide acá: `POST /api/voice/token` autoriza contra `voice-access` de `servers` (`VOICE_AUTHZ_MODE=servers_api`), que responde `403` a un suspendido, y voz devuelve `403 voice_forbidden`. Con `VOICE_AUTHZ_MODE=allow_authenticated` (solo desarrollo) un suspendido sí podría entrar. Si voz estaba caída cuando se suspendió al usuario, puede seguir en la sala hasta que venza el token de LiveKit (1 hora); `make republish-suspensions` en admin re-publica las suspensiones vigentes.

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

En local, cada réplica debe usar un `VOICE_INSTANCE_ID` distinto. El valor de
`.env.example` (`local-signaling-1`) es sólo para una instancia; al escalar
manualmente hay que sobrescribirlo por réplica para que RabbitMQ no comparta la
misma cola entre procesos.

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
