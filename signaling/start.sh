#!/bin/sh
set -e

mkdir -p /var/lib/tailscale /var/run/tailscale

# Por si la VM no trae el dispositivo TUN
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
fi

/app/tailscaled --state=/var/lib/tailscale/tailscaled.state \
                --socket=/var/run/tailscale/tailscaled.sock &

# Si Tailscale no conecta, la app arranca igual (el publisher reintenta solo)
HOSTNAME_SUFFIX="${FLY_ALLOC_ID:-${FLY_MACHINE_ID:-}}"
if [ -n "$HOSTNAME_SUFFIX" ]; then
  TAILSCALE_HOSTNAME="discordia-${HOSTNAME_SUFFIX}"
else
  TAILSCALE_HOSTNAME="discordia-signaling"
fi

/app/tailscale up --auth-key="${TAILSCALE_AUTHKEY}" \
                  --hostname="${TAILSCALE_HOSTNAME}" \
                  --accept-dns=false \
                  --timeout=30s \
  || echo "tailscale up falló, arranco la app igual"

exec /app/bin/discordia_signaling start