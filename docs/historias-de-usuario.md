# Historias de usuario

Las historias del catálogo de la cátedra que resuelve este servicio, con su número. Las rutas completas con sus parámetros y respuestas están en [`openapi.yaml`](../openapi.yaml). Todas piden el JWT del usuario. Las novedades de presencia llegan por WebSocket (`/socket`), con un ticket de un solo uso que se pide con `POST /api/voice/socket-ticket`.

## Obligatorias

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 17 | Unirse a canal de voz de servidor | 11 | `POST /api/voice/token` entrega el token. Con él, el cliente se conecta directo a LiveKit. |
| 18 | Salir de canal de voz | 1 | `DELETE /api/voice/session` |
| 19 | Silenciar micrófono propio | 1 | Lo resuelve el cliente con el SDK de LiveKit, con el permiso de publicar que trae el token. |
| 20 | Ver participantes conectados | 3 | `GET /api/voice/participants` y el WebSocket de presencia |

## Optativas

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 50 | Iniciar y recibir llamada de voz privada | 13 | `POST /api/voice/calls` y `POST /api/voice/calls/{id}/accept`, `reject` y `finish` |
| 51 | Indicador de quién está hablando | 3 | Lo resuelve el cliente con los eventos de actividad de LiveKit. |
| 52 | Silenciar a otro participante localmente | 2 | Lo resuelve el cliente con el SDK de LiveKit. |
| 53 | Compartir pantalla | 8 | `POST /api/voice/screen-token` y `POST /api/voice/calls/{id}/screen-token` |
| 54 | Video en llamada | 8 | Lo resuelve el cliente con el SDK de LiveKit, con el token de la sala. |

## Historias en las que participa

Estas historias las completan otros servicios. Acá está la parte que le toca a `voice-sfu`:

| # | Historia | Qué hace este servicio |
|---|---|---|
| 29, 30, 69 | Suspensiones | Recibe el evento firmado de `admin` y saca de la sala de voz a quien corresponda. |
| 60 | Silenciar temporalmente a un miembro | Recibe el evento de `servers` y le quita el permiso de hablar. |
| 66 | Notificaciones push | Publica `voice.private_call` para que `notifications` avise de una llamada entrante. |

## Decisiones técnicas

- **Documento de la réplica de autorización de voz:** cómo `signaling` pasó de consultar a `servers` a usar su propia copia (está en el repositorio `docs`).
