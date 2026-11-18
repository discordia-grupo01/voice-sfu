#!/usr/bin/env python3
"""Falso local de messaging para la prueba de contrato.

El signaling consulta GET /v1/voice-access/<usuario>?conversation_id=... a messaging
para autorizar una llamada privada. Este servidor responde siempre que si, para que el
camino feliz de las llamadas se pueda recorrer sin messaging real.

Uso: messaging_stub.py <puerto> [direccion]   (solo para localhost)
"""
import json
import sys
from urllib.parse import parse_qs, urlparse
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        conversation_id = query.get("conversation_id", [None])[0]

        if not conversation_id:
            conversation_id = "550e8400-e29b-41d4-a716-446655440001"

        body = json.dumps(
            {"allowed": True, "conversation_id": conversation_id}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    HTTPServer((host, int(sys.argv[1])), Handler).serve_forever()
