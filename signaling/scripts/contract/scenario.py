"""Escenario de camino feliz para el test de contrato del signaling de voz.

Con datos al azar, Schemathesis casi nunca llega al 2xx de los flujos con estado
(entrar a un canal y compartir pantalla, llamadas privadas). Este escenario los
recorre con datos validos contra el servicio real, con un LiveKit local en modo
dev, y valida cada respuesta contra openapi.yaml con la misma libreria (status,
esquema, content-type, cabeceras). Escribe un HAR minimo para medir la cobertura.

Uso: scenario.py <openapi.yaml> <base_url> <har_de_salida>
Variables: TOKEN_A y TOKEN_B (JWT de dos usuarios), USER_A y USER_B (sus ids).
Solo usa valores de juguete.
"""

import json
import os
import sys
import uuid

import schemathesis

spec_path, BASE, HAR_OUT = sys.argv[1:4]
SCHEMA = schemathesis.openapi.from_path(spec_path)

TOKEN_A = os.environ["TOKEN_A"]
TOKEN_B = os.environ["TOKEN_B"]
USER_A = os.environ["USER_A"]
USER_B = os.environ["USER_B"]

CHANNEL = str(uuid.uuid4())
SERVER = str(uuid.uuid4())
CONVERSATION = str(uuid.uuid4())

entries = []
failures = []


def call(method, path, expect, bearer=None, body=None, path_parameters=None, query=None):
    """Hace la llamada, valida la respuesta contra el contrato y la registra."""
    kwargs = {}
    if body is not None:
        kwargs["body"] = body
    if path_parameters:
        kwargs["path_parameters"] = path_parameters
    if query:
        kwargs["query"] = query
    if bearer:
        kwargs["headers"] = {"Authorization": f"Bearer {bearer}"}
    case = SCHEMA[path][method].Case(**kwargs)
    response = case.call(base_url=BASE)
    entries.append(
        {
            "request": {"method": method, "url": response.request.url},
            "response": {"status": response.status_code},
        }
    )
    if response.status_code != expect:
        failures.append(f"{method} {path}: se esperaba {expect} y llego {response.status_code}: {response.text[:200]}")
        return response
    try:
        case.validate_response(response)
    except Exception as exc:  # FailureGroup con el detalle de cada check
        failures.append(f"{method} {path}: la respuesta no cumple el contrato: {exc}")
    return response


def main():
    # Salud.
    call("GET", "/livez", 200)
    call("GET", "/readyz", 200)

    # Ticket para el socket de presencia.
    call("POST", "/api/voice/socket-ticket", 200, bearer=TOKEN_A)

    # Canal de voz: entrar, compartir pantalla, ver participantes y salir (dos veces: idempotente).
    call("POST", "/api/voice/token", 200, bearer=TOKEN_A, body={"channel_id": CHANNEL})
    call("POST", "/api/voice/screen-token", 200, bearer=TOKEN_A, body={"channel_id": CHANNEL})
    call("GET", "/api/voice/participants", 200, bearer=TOKEN_A, query={"server_id": SERVER})
    call("DELETE", "/api/voice/session", 204, bearer=TOKEN_A, body={"channel_id": CHANNEL})
    call("DELETE", "/api/voice/session", 204, bearer=TOKEN_A, body={"channel_id": CHANNEL})

    # Llamada privada: A llama a B, B acepta, A comparte pantalla y B corta.
    created = call(
        "POST",
        "/api/voice/calls",
        201,
        bearer=TOKEN_A,
        body={"recipient_id": USER_B},
    )
    call_id = created.json()["call_id"]
    call("POST", "/api/voice/calls/{id}/accept", 200, bearer=TOKEN_B, path_parameters={"id": call_id})
    call("POST", "/api/voice/calls/{id}/screen-token", 200, bearer=TOKEN_A, path_parameters={"id": call_id})
    call("POST", "/api/voice/calls/{id}/finish", 204, bearer=TOKEN_B, path_parameters={"id": call_id})

    # Otra llamada que B rechaza.
    created = call(
        "POST",
        "/api/voice/calls",
        201,
        bearer=TOKEN_A,
        body={"recipient_id": USER_B, "conversation_id": CONVERSATION},
    )
    call("POST", "/api/voice/calls/{id}/reject", 204, bearer=TOKEN_B, path_parameters={"id": created.json()["call_id"]})


try:
    main()
finally:
    with open(HAR_OUT, "w", encoding="utf-8") as f:
        json.dump({"log": {"entries": entries}}, f)

if failures:
    print("scenario: fallas en el camino feliz:", file=sys.stderr)
    for failure in failures:
        print("  - " + failure, file=sys.stderr)
    sys.exit(1)
print(f"scenario: {len(entries)} llamadas validadas contra el contrato")
