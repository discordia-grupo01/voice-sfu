#!/usr/bin/env bash
# Prueba de contrato: levanta el signaling contra Postgres, RabbitMQ y un LiveKit LOCALES
# (modo dev, claves de juguete), recorre el camino feliz con un escenario y corre Schemathesis
# con ../openapi.yaml. Sale con 0 solo si no encuentra desvios.
#
# Configuracion por variables de entorno (sin argumentos):
#   APP_PORT               puerto del servicio (18088)
#   DATABASE_URL           Postgres de prueba; el host debe ser localhost/127.0.0.1
#   RABBITMQ_URL           RabbitMQ de prueba; el host debe ser localhost/127.0.0.1
#   LIVEKIT_URL            LiveKit local en modo dev (ws://localhost:57880); host local
#   MESSAGING_STUB_PORT    puerto del falso de messaging para las llamadas privadas (55528)
#   CONTRACT_APP_MODE      host (mix run, por defecto) o docker (contenedor elixir:1.17.3-otp-27)
#   CONTRACT_MAX_EXAMPLES  casos por operacion (50)
#   CONTRACT_SEED          semilla (1)
#   CONTRACT_REPORT_DIR    carpeta del reporte (contract-report)
#   SCHEMATHESIS_BIN       ejecutable de Schemathesis (.contract-venv, o el del PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SPEC="../openapi.yaml"

APP_PORT="${APP_PORT:-18088}"
DATABASE_URL="${DATABASE_URL:-postgres://discordia:discordia@localhost:55508/discordia_voice}"
RABBITMQ_URL="${RABBITMQ_URL:-amqp://guest:guest@localhost:55518}"
LIVEKIT_URL="${LIVEKIT_URL:-ws://localhost:57880}"
MESSAGING_STUB_PORT="${MESSAGING_STUB_PORT:-55528}"
CONTRACT_APP_MODE="${CONTRACT_APP_MODE:-host}"
CONTRACT_MAX_EXAMPLES="${CONTRACT_MAX_EXAMPLES:-50}"
CONTRACT_SEED="${CONTRACT_SEED:-1}"
CONTRACT_REPORT_DIR="${CONTRACT_REPORT_DIR:-contract-report}"
CONTRACT_READY_TIMEOUT="${CONTRACT_READY_TIMEOUT:-900}"
APP_CONTAINER="contract-voice-app"
BASE_URL="http://127.0.0.1:${APP_PORT}"

# Valores de juguete: no son secretos reales. Las claves de LiveKit son las del contenedor dev.
JWT_SECRET="contract-test-secret"
LIVEKIT_API_KEY="devkey"
LIVEKIT_API_SECRET="devsecret"
USER_A="00000000-0000-4000-8000-0000000000a1"
USER_B="00000000-0000-4000-8000-0000000000b2"

log() { echo "[contract] $*"; }
die() { echo "[contract] ERROR: $*" >&2; exit 1; }

# Host de una URL (postgres://u:p@host:1234/db, amqp://..., ws://...). Vacio si no se puede leer.
url_host() {
  local rest="${1#*://}"
  rest="${rest%%/*}"
  rest="${rest##*@}"
  rest="${rest%%:*}"
  echo "$rest"
}

# Proteccion contra produccion: solo se aceptan una base, un broker y un LiveKit locales.
guard_local() {
  local name="$1" url="$2" host
  host="$(url_host "$url")"
  case "$host" in
    localhost | 127.0.0.1) ;;
    *) die "$name apunta a '$host': la prueba de contrato solo corre contra localhost/127.0.0.1" ;;
  esac
}

guard_local DATABASE_URL "$DATABASE_URL"
guard_local RABBITMQ_URL "$RABBITMQ_URL"
guard_local LIVEKIT_URL "$LIVEKIT_URL"
case "$CONTRACT_APP_MODE" in host | docker) ;; *) die "CONTRACT_APP_MODE debe ser host o docker" ;; esac

# Python y Schemathesis
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for candidate in python3 python; do
    if "$candidate" -c 'import sys' > /dev/null 2>&1; then PY="$candidate"; break; fi
  done
fi
[ -n "$PY" ] || die "no encuentro Python 3"
if [ -z "${SCHEMATHESIS_BIN:-}" ]; then
  if [ -x "../.contract-venv/bin/schemathesis" ]; then
    SCHEMATHESIS_BIN="../.contract-venv/bin/schemathesis"
  elif [ -x "../.contract-venv/Scripts/schemathesis.exe" ]; then
    SCHEMATHESIS_BIN="../.contract-venv/Scripts/schemathesis.exe"
  elif command -v schemathesis > /dev/null 2>&1; then
    SCHEMATHESIS_BIN="schemathesis"
  else
    die "no encuentro schemathesis: python -m venv .contract-venv && .contract-venv/bin/pip install schemathesis==4.33.4 (en la raiz del repo)"
  fi
fi
# Python del mismo entorno que Schemathesis (trae PyYAML) para el escenario y la cobertura.
if [ -x "../.contract-venv/bin/python" ]; then
  PY_VENV="../.contract-venv/bin/python"
elif [ -x "../.contract-venv/Scripts/python.exe" ]; then
  PY_VENV="../.contract-venv/Scripts/python.exe"
else
  PY_VENV="$PY"
fi

TOKEN_A="$("$PY" scripts/contract/make_token.py "$USER_A" "$JWT_SECRET" 3600)"
TOKEN_B="$("$PY" scripts/contract/make_token.py "$USER_B" "$JWT_SECRET" 3600)"

APP_PID=""
STUB_PID=""
cleanup() {
  local status=$?
  for pid in "$APP_PID" "$STUB_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" > /dev/null 2>&1 || true
      wait "$pid" > /dev/null 2>&1 || true
    fi
  done
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker rm -f "$APP_CONTAINER" > /dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# Falso de messaging: autoriza las llamadas privadas sin un messaging real.
"$PY" scripts/contract/messaging_stub.py "$MESSAGING_STUB_PORT" 127.0.0.1 &
STUB_PID=$!

# Lo que el servicio recibe: valores de juguete y nada que salga de la maquina.
APP_ENV=(
  "MIX_ENV=prod"
  "SECRET_KEY_BASE=contract-test-secret-key-base-contract-test-secret-key-base-0123456789abcdef"
  "LOG_LEVEL=warning"
  "JWT_SECRET=$JWT_SECRET"
  "LIVEKIT_API_KEY=$LIVEKIT_API_KEY"
  "LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET"
  "VOICE_AUTHZ_MODE=allow_authenticated"
  "ADMIN_EVENTS_HMAC_SECRET=contract-test-hmac"
)
UNSET_ENV=(OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS LOG_SHIP_URL LOG_SHIP_API_KEY
  SERVERS_URL SERVERS_HEALTH_URL TAILSCALE_AUTHKEY)

if docker ps -a --format '{{.Names}}' 2> /dev/null | grep -qx "$APP_CONTAINER"; then
  docker rm -f "$APP_CONTAINER" > /dev/null
fi

mkdir -p "$CONTRACT_REPORT_DIR"
APP_LOG="$CONTRACT_REPORT_DIR/app.log"

if [ "$CONTRACT_APP_MODE" = "host" ]; then
  log "arrancando el servicio con mix en el puerto $APP_PORT"
  (
    for name in "${UNSET_ENV[@]}"; do unset "$name"; done
    for pair in "${APP_ENV[@]}"; do export "$pair"; done
    export PORT="$APP_PORT" LIVEKIT_URL RABBITMQ_URL
    export VOICE_EVENTS_DATABASE_URL="$DATABASE_URL" VOICE_REPLICA_DATABASE_URL="$DATABASE_URL"
    export MESSAGING_URL="http://127.0.0.1:$MESSAGING_STUB_PORT"
    exec mix run --no-halt
  ) > "$APP_LOG" 2>&1 &
  APP_PID=$!
else
  # En docker el contenedor llega al host por host.docker.internal; las URLs ya pasaron el guard.
  container_url() { echo "$1" | sed -e 's#@localhost#@host.docker.internal#' -e 's#//localhost#//host.docker.internal#' -e 's#@127.0.0.1#@host.docker.internal#' -e 's#//127.0.0.1#//host.docker.internal#'; }
  log "arrancando el servicio en el contenedor $APP_CONTAINER (puerto $APP_PORT)"
  docker_env=()
  for pair in "${APP_ENV[@]}"; do docker_env+=(-e "$pair"); done
  # El falso de messaging escucha en 127.0.0.1 del host; host.docker.internal lo alcanza.
  MSYS_NO_PATHCONV=1 docker run -d --name "$APP_CONTAINER" \
    -p "127.0.0.1:${APP_PORT}:4000" \
    -v "$(pwd -W 2> /dev/null || pwd):/app" \
    -v contract-voice-deps:/app/deps \
    -v contract-voice-build:/app/_build \
    -w /app "${docker_env[@]}" \
    -e "PORT=4000" \
    -e "LIVEKIT_URL=$(container_url "$LIVEKIT_URL")" \
    -e "RABBITMQ_URL=$(container_url "$RABBITMQ_URL")" \
    -e "VOICE_EVENTS_DATABASE_URL=$(container_url "$DATABASE_URL")" \
    -e "VOICE_REPLICA_DATABASE_URL=$(container_url "$DATABASE_URL")" \
    -e "MESSAGING_URL=http://host.docker.internal:$MESSAGING_STUB_PORT" \
    elixir:1.17.3-otp-27 sh -c "mix local.hex --force && mix local.rebar --force && mix deps.get && mix run --no-halt" \
    > /dev/null
fi

app_alive() {
  if [ "$CONTRACT_APP_MODE" = "host" ]; then
    kill -0 "$APP_PID" > /dev/null 2>&1
  else
    [ "$(docker inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2> /dev/null)" = "true" ]
  fi
}

show_app_log() {
  if [ "$CONTRACT_APP_MODE" = "docker" ]; then
    docker logs "$APP_CONTAINER" > "$APP_LOG" 2>&1 || true
  fi
  grep -v '"status":4[0-9][0-9]' "$APP_LOG" | tail -n 15 >&2 || true
}

log "esperando /readyz (hasta ${CONTRACT_READY_TIMEOUT}s; la primera compilacion tarda)"
waited=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/readyz" 2> /dev/null || true)" = "200" ]; do
  if ! app_alive; then
    show_app_log
    die "el servicio se cayo antes de quedar listo"
  fi
  if [ "$waited" -ge "$CONTRACT_READY_TIMEOUT" ]; then
    show_app_log
    die "el servicio no quedo listo en ${CONTRACT_READY_TIMEOUT}s (LiveKit en $LIVEKIT_URL?)"
  fi
  sleep 2
  waited=$((waited + 2))
done
log "servicio listo"

export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
status=0

# Camino feliz de los flujos con estado: lo recorre un escenario con datos validos y valida cada
# respuesta contra el contrato. Deja un HAR para medir la cobertura.
log "escenario de camino feliz"
TOKEN_A="$TOKEN_A" TOKEN_B="$TOKEN_B" USER_A="$USER_A" USER_B="$USER_B" \
  "$PY_VENV" scripts/contract/scenario.py "$SPEC" "$BASE_URL" "$CONTRACT_REPORT_DIR/har-scenario.json" || status=$?

log "corriendo Schemathesis ($CONTRACT_MAX_EXAMPLES casos por operacion, semilla $CONTRACT_SEED)"
set +e
"$SCHEMATHESIS_BIN" --config-file scripts/contract/schemathesis.toml run "$SPEC" \
  --url "$BASE_URL" \
  --header "Authorization: Bearer $TOKEN_A" \
  --max-examples "$CONTRACT_MAX_EXAMPLES" \
  --seed "$CONTRACT_SEED" \
  --workers 1 \
  --report junit,har --report-dir "$CONTRACT_REPORT_DIR" \
  --no-color
st_status=$?
set -e
[ "$st_status" -eq 0 ] || status=$st_status

# Cobertura de camino feliz: cuantas operaciones del contrato obtuvieron un 2xx real.
"$PY_VENV" scripts/contract/coverage.py "$SPEC" "$CONTRACT_REPORT_DIR"/har-*.json || status=$?

if [ "$status" -ne 0 ]; then
  show_app_log
  log "la prueba de contrato fallo (reporte en $CONTRACT_REPORT_DIR)"
fi
exit "$status"
