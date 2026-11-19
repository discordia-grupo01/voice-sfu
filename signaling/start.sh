#!/bin/sh
set -e

STATE_DIR=/var/lib/tailscale
SOCK=/var/run/tailscale/tailscaled.sock
AUTHKEY="${TAILSCALE_AUTHKEY:-${TS_AUTHKEY:-}}"

mkdir -p "$STATE_DIR" /var/run/tailscale

if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
fi

# Supervision: reinicia tailscaled si se cae. OJO: --state necesita un valor;
# sin el, tailscaled tomaba "--socket=..." como ruta del estado.
(
  while true; do
    /app/tailscaled --state="$STATE_DIR/tailscaled.state" --socket="$SOCK"
    echo "tailscaled se detuvo, reiniciando en 2s..."
    sleep 2
  done
) &

TRIES=0
while [ ! -S "$SOCK" ] && [ "$TRIES" -lt 50 ]; do
  sleep 0.2
  TRIES=$((TRIES + 1))
done

HOSTNAME_SUFFIX="${FLY_MACHINE_ID:-${FLY_ALLOC_ID:-local}}"
TAILSCALE_HOSTNAME="discordia-${HOSTNAME_SUFFIX}"

ts_up() {
  /app/tailscale --socket="$SOCK" up \
    --auth-key="${AUTHKEY}" \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --accept-dns=false \
    --timeout=30s
}

if [ -z "$AUTHKEY" ]; then
  echo "ADVERTENCIA: falta el secret TAILSCALE_AUTHKEY (o TS_AUTHKEY); sin Tailscale no hay acceso a RabbitMQ ni a servers"
fi

# Reintenta al arrancar (la red de la VM puede tardar unos segundos)
ATTEMPT=1
until ts_up; do
  if [ "$ATTEMPT" -ge 3 ]; then
    echo "tailscale up falló $ATTEMPT veces, arranco la app igual y sigo reintentando en segundo plano"
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 3
done

# Vigilante: si la VPN se cae o nunca subió, vuelve a levantarla
(
  while true; do
    sleep 30
    if ! /app/tailscale --socket="$SOCK" status >/dev/null 2>&1; then
      echo "tailscale no está activo, reintentando"
      ts_up || true
    fi
  done
) &

exec /app/bin/discordia_signaling start
