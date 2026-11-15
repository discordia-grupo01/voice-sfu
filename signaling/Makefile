.PHONY: test coverage format sobelow openapi contract-deps-up contract-deps-down contract-test

test:
	mix test --cover

coverage:
	mix test --cover

format:
	mix format

sobelow:
	mix sobelow --config

# Genera ../openapi.yaml desde el router y los controladores (open_api_spex).
openapi:
	mix openapi.spec.yaml --spec DiscordiaSignalingWeb.ApiSpec ../openapi.yaml

# Prueba de contrato (Schemathesis contra el servicio real). Contenedores propios y puertos de
# host: Postgres 55508, RabbitMQ 55518, LiveKit en modo dev 57880; el servicio corre en 18088.
CONTRACT_PG_PORT ?= 55508
CONTRACT_RABBITMQ_PORT ?= 55518
CONTRACT_LIVEKIT_PORT ?= 57880

contract-deps-up:
	@docker rm -f contract-voice-pg contract-voice-rabbitmq contract-voice-livekit >/dev/null 2>&1 || true
	docker run -d --name contract-voice-pg -e POSTGRES_DB=discordia_voice -e POSTGRES_USER=discordia -e POSTGRES_PASSWORD=discordia -p 127.0.0.1:$(CONTRACT_PG_PORT):5432 postgres:16-alpine >/dev/null
	docker run -d --name contract-voice-rabbitmq -p 127.0.0.1:$(CONTRACT_RABBITMQ_PORT):5672 rabbitmq:3.13-management-alpine >/dev/null
	docker run -d --name contract-voice-livekit -p 127.0.0.1:$(CONTRACT_LIVEKIT_PORT):7880 livekit/livekit-server:latest --dev --keys "devkey: devsecret" >/dev/null
	@until docker exec contract-voice-pg pg_isready -U discordia >/dev/null 2>&1; do sleep 2; done
	@until docker exec contract-voice-rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; do sleep 2; done
	@until curl -s -o /dev/null http://127.0.0.1:$(CONTRACT_LIVEKIT_PORT); do sleep 2; done
	@echo "Postgres en $(CONTRACT_PG_PORT), RabbitMQ en $(CONTRACT_RABBITMQ_PORT) y LiveKit en $(CONTRACT_LIVEKIT_PORT) listos"

contract-deps-down:
	@docker rm -f contract-voice-app contract-voice-pg contract-voice-rabbitmq contract-voice-livekit >/dev/null 2>&1 || true
	@echo "Contenedores de contrato apagados"

contract-test:
	APP_PORT=18088 	DATABASE_URL=postgres://discordia:discordia@localhost:$(CONTRACT_PG_PORT)/discordia_voice 	RABBITMQ_URL=amqp://guest:guest@localhost:$(CONTRACT_RABBITMQ_PORT) 	LIVEKIT_URL=ws://localhost:$(CONTRACT_LIVEKIT_PORT) 	./scripts/contract-test.sh
