# --- Etapa 1: Builder ---
FROM elixir:1.17.3-otp-26-alpine AS builder

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

# --- Etapa 2: Runner ---
FROM elixir:1.17.3-otp-26-alpine AS app

WORKDIR /app

ENV MIX_ENV=prod
ENV PORT=4000

COPY --from=builder /app/_build/prod/rel/discordia_signaling ./

EXPOSE 4000

CMD ["bin/discordia_signaling", "start"]