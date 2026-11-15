# voice-sfu

Servicio de voz de Discordia.

## Tabla de contenidos

- [Introducción](#introducción)
- [Pre-requisitos](#pre-requisitos)
- [Cómo correr](#cómo-correr)
- [Variables de entorno](#variables-de-entorno)
- [Comandos Docker](#comandos-docker)
- [Tests](#tests)
- [Más documentación](#más-documentación)

## Introducción

`voice-sfu` es todo lo que hace falta para hablar por voz en Discordia. Tiene dos partes:

- **signaling:** una aplicación Elixir con Phoenix (carpeta [`signaling`](signaling)) que decide quién puede entrar a un canal de voz y le entrega un token. También lleva la cuenta de quién está en cada sala, avisa a los clientes por WebSocket quién entra y sale, y maneja las llamadas privadas uno a uno y el compartir pantalla.
- **LiveKit:** el servidor de medios (SFU) que recibe y reparte el audio. Se usa tal cual, con la configuración de [`livekit.yaml`](livekit.yaml) en local y la carpeta [`livekit`](livekit) para desplegarlo.

El audio no pasa por `signaling`: el cliente le pide un token y con él se conecta directo a LiveKit por WebRTC. `signaling` solo firma ese token con los permisos del usuario y después controla las salas (expulsar a alguien, silenciarlo).

Para decidir si un usuario puede entrar a un canal, `signaling` usa su propia copia de los roles, permisos y miembros de cada servidor, que mantiene al día con los eventos de RabbitMQ y guarda en su base PostgreSQL. En esa misma base anota los eventos que publica (quién entró o salió de una sala) antes de mandarlos a RabbitMQ, para no perderlos. Las llamadas privadas consultan a `messaging` por HTTP para comprobar que los dos usuarios están en la conversación y que no hay un bloqueo entre ellos.

El JWT lo valida el gateway (Kong) y este servicio también lo verifica con `JWT_SECRET`. La API REST está descripta en [`openapi.yaml`](openapi.yaml).

## Pre-requisitos

- **Docker** y **Docker Compose** v2.24 o más nuevo.
- **RabbitMQ**, que se levanta con el repositorio [`rabbit-mq`](https://github.com/discordia-grupo01/rabbit-mq). Sin él, `signaling` arranca igual y reintenta conectarse, pero no recibe permisos ni publica presencia.
- **Elixir 1.17.3** y **Erlang/OTP 27**, solo si querés correr `signaling` en tu máquina.
- Un cliente con el SDK de LiveKit, solo si querés probar el audio de verdad. Con la web o la app del proyecto alcanza.

## Cómo correr

### Con Docker Compose

Levanta `signaling`, LiveKit y la base PostgreSQL, sin configurar nada:

```bash
docker compose up --build
```

Cuando todo esté arriba, comprobá que el servicio esté vivo. `/readyz` además verifica que pueda hablar con LiveKit:

```bash
curl http://localhost:4000/readyz
```

Para pedir un token de voz necesitás un JWT firmado con `JWT_SECRET` (el compose trae uno de ejemplo). En local, `VOICE_AUTHZ_MODE=allow_authenticated` deja entrar a cualquier usuario autenticado a cualquier canal, así no hace falta tener cargados servidores ni permisos:

```bash
curl -X POST http://localhost:4000/api/voice/token \
  -H "Authorization: Bearer <tu JWT>" \
  -H "Content-Type: application/json" \
  -d '{"channel_id": "22222222-2222-4222-8222-222222222222"}'
```

Si querés cambiar puertos, secretos o el modo de autorización, copiá el archivo de ejemplo y editalo antes de levantar:

```bash
cp .env.example .env
```

Este compose levanta solo lo que es de este servicio. Para el sistema completo (con el gateway y los demás servicios) usá el compose del repositorio `infrastructure`.

### Con eventos (RabbitMQ)

Para que `signaling` reciba los permisos y publique presencia, levantá primero RabbitMQ desde el repositorio `rabbit-mq`:

```bash
cd ../rabbit-mq
docker compose up -d
```

El compose ya apunta a `host.docker.internal:5672`, que desde un contenedor es tu máquina. Si lo levantaste en otro lado, completá `RABBITMQ_URL_DOCKER` en el `.env`.

### Para desarrollar

Si vas a tocar el código de `signaling`, te conviene correrlo en tu máquina y dejar en contenedores solo LiveKit y la base:

```bash
cp .env.example .env
docker compose up -d livekit db
cd signaling
mix deps.get
mix phx.server
```

## Variables de entorno

Se leen del entorno o de un archivo `.env`. El archivo [`.env.example`](.env.example) trae valores listos para correr en local.

| Variable | Default | Descripción |
|---|---|---|
| `PORT` | `4000` | Puerto donde escucha `signaling`. |
| `SECRET_KEY_BASE` | obligatoria | Secreto de Phoenix, de al menos 64 caracteres. |
| `JWT_SECRET` | obligatoria | Secreto con el que se valida el JWT del usuario. Es un secreto. |
| `PHOENIX_CHECK_ORIGINS` | los dominios de la web | Orígenes permitidos para el WebSocket, separados por coma. |
| `LIVEKIT_URL` | `ws://localhost:7880` | URL de LiveKit. `signaling` la usa para controlar las salas y se la entrega a los clientes para conectarse. |
| `LIVEKIT_API_KEY` | `devkey` | Clave de la API de LiveKit. |
| `LIVEKIT_API_SECRET` | `devsecret` | Secreto de la API de LiveKit. Es un secreto. |
| `LIVEKIT_TOKEN_TTL_SECONDS` | `3600` | Cuánto dura un token de voz. |
| `VOICE_AUTHZ_MODE` | `deny` | Cómo se decide si un usuario puede entrar a un canal: `replica` (usa la copia local, es lo que va en producción), `servers_api` (le pregunta a `servers` por HTTP), `replica_shadow` (compara las dos y sigue con `servers`) o `allow_authenticated` (deja entrar a cualquiera con JWT, solo local). Sin valor, `deny` rechaza todo. |
| `SERVERS_URL` | `http://servers:8080` | URL de `servers`. Solo con `servers_api` o `replica_shadow`. |
| `SERVERS_HEALTH_URL` | vacío | Ruta de salud de `servers` que mira `/readyz`, si `SERVERS_URL` apunta al gateway. |
| `MESSAGING_URL` | `http://messaging:4000` | URL de `messaging`, para autorizar llamadas privadas. |
| `RABBITMQ_URL` | vacío | Conexión a RabbitMQ. Vacía = el servicio arranca pero no consume ni publica eventos. |
| `EVENTS_EXCHANGE` | `discordia.events` | Exchange compartido por los servicios. |
| `VOICE_EVENTS_QUEUE` | `voice.signaling` | Prefijo de las colas de este servicio. |
| `VOICE_INSTANCE_ID` | el id de la máquina | Nombre de esta instancia. Cada instancia tiene sus propias colas. |
| `ADMIN_EVENTS_HMAC_SECRET` | vacío | Secreto compartido con `admin` para verificar las suspensiones. Es un secreto. |
| `VOICE_REPLICA_DATABASE_URL` | una base local | Conexión a PostgreSQL de la copia de permisos. |
| `VOICE_EVENTS_DATABASE_URL` | la misma que la anterior | Conexión a PostgreSQL de los eventos publicados y consumidos. |
| `TS_AUTHKEY` | vacío | Clave de Tailscale. Si está, el contenedor entra a la red privada. Solo en producción. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | vacío | Backend OpenTelemetry (por ejemplo New Relic). Vacío = sin trazas ni métricas. |
| `OTEL_EXPORTER_OTLP_HEADERS` | vacío | Credenciales del backend. Es un secreto. |
| `LOG_SHIP_URL` | vacío | Si se completa, también manda los logs a New Relic. |

Variables que usa solo `docker-compose.yml`:

| Variable | Default | Descripción |
|---|---|---|
| `SIGNALING_PORT` | `4000` | Puerto de `signaling` en tu máquina. |
| `DATABASE_PORT` | `5434` | Puerto de PostgreSQL en tu máquina. |
| `LIVEKIT_PUBLIC_URL` | `ws://host.docker.internal:7880` | URL de LiveKit para `signaling` y para los clientes. |
| `RABBITMQ_URL_DOCKER` | `amqp://guest:guest@host.docker.internal:5672/` | Conexión a RabbitMQ para el servicio que corre dentro del compose. |

LiveKit publica el puerto `7880` (WebSocket), `7881` (TCP) y los puertos UDP `51000` a `51010`.

## Comandos Docker

Todos desde la raíz del repositorio.

| Qué querés hacer | Comando |
|---|---|
| Levantar todo | `docker compose up --build` |
| Levantar todo en segundo plano | `docker compose up -d --build` |
| Levantar solo LiveKit y la base | `docker compose up -d livekit db` |
| Ver los logs de signaling | `docker compose logs -f signaling` |
| Ver qué está corriendo | `docker compose ps` |
| Reconstruir solo signaling | `docker compose up -d --build signaling` |
| Abrir una consola de la base | `docker compose exec db psql -U discordia -d discordia_voice` |
| Bajar todo, conservando los datos | `docker compose down` |
| Bajar todo y borrar los datos | `docker compose down -v` |

Las tablas de la base las crea `signaling` solo, al arrancar.

Dentro de un contenedor, `LIVEKIT_URL`, `MESSAGING_URL` y `RABBITMQ_URL` no pueden apuntar a `localhost`: tienen que usar el nombre del contenedor o `host.docker.internal`.

## Tests

Desde la carpeta `signaling`:

```bash
cd signaling
mix test --cover
```

El CI exige una cobertura mínima del 70 %. También corre `make sobelow`, el análisis de seguridad del código.

La carpeta [`connectivity-tests`](connectivity-tests) tiene scripts para comprobar la conexión WebRTC contra LiveKit.

## Más documentación

En este repositorio:

- [`docs/historias-de-usuario.md`](docs/historias-de-usuario.md): las historias del catálogo que resuelve este servicio.
- [`openapi.yaml`](openapi.yaml): contrato de la API REST.
- [`signaling/README.md`](signaling/README.md): detalle de `signaling`, sus health checks y sus logs.

En el repositorio [`docs`](https://github.com/discordia-grupo01/docs):

- [`asyncapi`](https://github.com/discordia-grupo01/docs/tree/main/asyncapi): los eventos que este servicio publica y consume.
