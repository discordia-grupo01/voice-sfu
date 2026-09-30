FROM elixir:1.17.3-otp-27-alpine

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs ./
COPY config ./config
RUN mix deps.get --only prod

COPY lib ./lib
RUN mix compile

EXPOSE 4000
CMD ["mix", "phx.server"]
