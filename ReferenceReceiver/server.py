#!/usr/bin/env python3
"""Dependency-free test receiver for TwainBridge multipart uploads.

This is intentionally a development fixture, not a production web server.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import ssl
import time
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


MAX_REQUEST_BYTES = 150 * 1024 * 1024
SEEN: dict[str, dict] = {}
ATTEMPTS: dict[str, int] = {}


def parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], list[dict]]:
    message = BytesParser(policy=default).parsebytes(
        b"MIME-Version: 1.0\r\nContent-Type: "
        + content_type.encode("ascii", "strict")
        + b"\r\n\r\n"
        + body
    )
    fields: dict[str, str] = {}
    files: list[dict] = []
    if not message.is_multipart():
        raise ValueError("request is not multipart/form-data")
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if not name:
            continue
        if filename is not None:
            files.append(
                {
                    "field": name,
                    "filename": filename,
                    "content_type": part.get_content_type(),
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )
        else:
            fields[name] = payload.decode(part.get_content_charset() or "utf-8", "replace")
    return fields, files


class Receiver(BaseHTTPRequestHandler):
    server_version = "TwainBridgeReferenceReceiver/1.0"

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            self.send_json(200, {"success": True, "message": "Reference receiver is ready"})
        elif path == "/state":
            self.send_json(200, {"success": True, "operations": list(SEEN.values())})
        else:
            self.send_json(404, {"success": False, "message": "Unknown endpoint"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/upload":
            self.send_json(404, {"success": False, "message": "Unknown endpoint"})
            return
        options = parse_qs(parsed.query)
        mode = options.get("mode", ["success"])[0]
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, {"success": False, "message": "Invalid Content-Length"})
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(413, {"success": False, "message": "Request size rejected"})
            return
        try:
            fields, files = parse_multipart(
                self.headers.get("Content-Type", ""), self.rfile.read(length)
            )
        except (ValueError, UnicodeError) as error:
            self.send_json(400, {"success": False, "message": str(error)})
            return

        key = self.headers.get("Idempotency-Key") or fields.get("document_id") or fields.get("batch_id")
        if not key:
            self.send_json(400, {"success": False, "message": "Missing idempotency identifier"})
            return
        ATTEMPTS[key] = ATTEMPTS.get(key, 0) + 1
        failure_count = int(options.get("failures", ["1"])[0])
        if mode == "retry" and ATTEMPTS[key] <= failure_count:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Retry-After", options.get("retry_after", ["0"])[0])
            self.end_headers()
            self.wfile.write(b'{"success":false,"message":"Planned retry"}')
            return
        if mode == "slow":
            time.sleep(float(options.get("seconds", ["5"])[0]))
        if mode == "malformed":
            self.send_bytes(200, b"{not-json", "application/json")
            return
        if mode == "oversized":
            size = int(options.get("bytes", [str(2 * 1024 * 1024)])[0])
            self.send_bytes(200, b"x" * size, "application/json")
            return
        if mode == "empty":
            self.send_bytes(204, b"", "application/json")
            return
        if mode == "status-only":
            self.send_bytes(204, b"", "text/plain")
            return
        if mode == "reject":
            self.send_json(422, {"success": False, "message": "Planned application rejection"})
            return

        document_ids = self.document_ids(fields)
        result = {
            "success": True,
            "message": "Document received",
            "id": "remote-" + hashlib.sha256(key.encode()).hexdigest()[:12],
            "documents": [
                {
                    "document_id": document_id,
                    "success": not (mode == "partial" and index == len(document_ids) - 1),
                    "id": "remote-" + hashlib.sha256(document_id.encode()).hexdigest()[:12],
                    "message": "Planned partial failure" if mode == "partial" and index == len(document_ids) - 1 else "Received",
                }
                for index, document_id in enumerate(document_ids)
            ],
        }
        if fields.get("batch_id"):
            result["batch_id"] = fields["batch_id"]
        SEEN[key] = {
            "idempotency_key": key,
            "attempts": ATTEMPTS[key],
            "fields": sorted(fields.keys()),
            "files": files,
            "document_ids": document_ids,
        }
        self.send_json(200, result)

    @staticmethod
    def document_ids(fields: dict[str, str]) -> list[str]:
        if "manifest" in fields:
            try:
                return [str(row["document_id"]) for row in json.loads(fields["manifest"])["documents"]]
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                return []
        return [fields["document_id"]] if fields.get("document_id") else []

    def send_json(self, status: int, value: dict) -> None:
        self.send_bytes(status, json.dumps(value, separators=(",", ":")).encode(), "application/json")

    def send_bytes(self, status: int, value: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(value)))
        self.end_headers()
        self.wfile.write(value)

    def log_message(self, fmt: str, *args: object) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="TwainBridge reference HTTPS receiver")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert", help="PEM TLS certificate")
    parser.add_argument("--key", help="PEM TLS private key")
    parser.add_argument("--http", action="store_true", help="Allow plain HTTP for receiver-only tests")
    args = parser.parse_args()
    if not args.http and not (args.cert and args.key):
        parser.error("HTTPS is the default; provide --cert and --key, or use --http for receiver-only tests")
    server = ThreadingHTTPServer((args.host, args.port), Receiver)
    scheme = "http"
    if not args.http:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    actual_port = server.server_address[1]
    print(f"Listening on {scheme}://{args.host}:{actual_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
