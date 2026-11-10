# --- Etapa 1: Builder ---
FROM elixir:1.17.3-otp-27-alpine AS builder

WORKDIR /app

ENV MIX_ENV=prod

RUN apk add --no-cache git && mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

# --- Etapa 2: Runner ---
# --- Etapa 2: Runner ---
FROM elixir:1.17.3-otp-27-alpine AS app

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=4000

RUN apk add --no-cache ca-certificates

COPY --from=builder /app/_build/prod/rel/discordia_signaling ./

COPY --from=docker.io/tailscale/tailscale:stable /usr/local/bin/tailscaled /app/tailscaled
COPY --from=docker.io/tailscale/tailscale:stable /usr/local/bin/tailscale /app/tailscale

COPY start.sh /app/start.sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh

EXPOSE 4000

CMD ["/app/start.sh"]