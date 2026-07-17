#!/usr/bin/env python3
"""A dependency-free, persistent demo receiver for TwainBridge uploads."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import ssl
import sys
import threading
import uuid
from datetime import datetime, timezone
from email.parser import BytesParser
from email.policy import default as email_policy
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlparse


MAX_REQUEST_BYTES = 150 * 1024 * 1024
MAX_FILE_BYTES = 100 * 1024 * 1024
ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SAFE_TEXT_PATTERN = re.compile(r"[\x00-\x1f\x7f]")
SUPPORTED_FILES = (
    (b"%PDF-", "application/pdf", ".pdf", "pdf"),
    (b"\xff\xd8\xff", "image/jpeg", ".jpg", "image"),
    (b"\x89PNG\r\n\x1a\n", "image/png", ".png", "image"),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def safe_text(value: object, limit: int = 240) -> str:
    if value is None:
        return ""
    cleaned = SAFE_TEXT_PATTERN.sub("", str(value)).strip()
    return cleaned[:limit]


def safe_filename(value: object, fallback: str) -> str:
    name = Path(safe_text(value, 180)).name
    name = re.sub(r"[^A-Za-z0-9._() -]+", "-", name).strip(" .-")
    return name or fallback


def detect_file(payload: bytes) -> tuple[str, str, str]:
    for magic, content_type, extension, kind in SUPPORTED_FILES:
        if payload.startswith(magic):
            return content_type, extension, kind
    raise ValueError("Only PDF, JPEG, and PNG uploads are supported.")


def parse_multipart(content_type: str, body: bytes) -> tuple[list[dict], dict[str, str]]:
    if "multipart/form-data" not in content_type.lower():
        raise ValueError("Content-Type must be multipart/form-data.")
    message = BytesParser(policy=email_policy).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
    )
    if not message.is_multipart():
        raise ValueError("Malformed multipart request.")

    files: list[dict] = []
    fields: dict[str, str] = {}
    for part in message.iter_parts():
        field = part.get_param("name", header="content-disposition")
        if not field:
            continue
        filename = part.get_filename()
        payload = part.get_payload(decode=True) or b""
        if filename is not None:
            files.append(
                {
                    "field": safe_text(field, 100),
                    "filename": safe_filename(filename, "document"),
                    "claimed_type": safe_text(part.get_content_type(), 100),
                    "payload": payload,
                }
            )
        else:
            charset = part.get_content_charset() or "utf-8"
            try:
                fields[safe_text(field, 100)] = payload.decode(charset, errors="replace")
            except LookupError:
                fields[safe_text(field, 100)] = payload.decode("utf-8", errors="replace")
    if not files:
        raise ValueError("No file parts were found in the upload.")
    return files, fields


def parse_manifest(fields: dict[str, str]) -> list[dict]:
    raw = fields.get("manifest", "").strip()
    if not raw:
        return []
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("The manifest field is not valid JSON.") from exc
    documents = manifest.get("documents", []) if isinstance(manifest, dict) else []
    if not isinstance(documents, list):
        raise ValueError("manifest.documents must be an array.")
    return [item if isinstance(item, dict) else {} for item in documents]


class LibraryStore:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir.resolve()
        self.files_dir = self.data_dir / "files"
        self.index_path = self.data_dir / "library.json"
        self.lock = threading.RLock()
        self.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.files_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.data_dir, 0o700)
        os.chmod(self.files_dir, 0o700)
        self.records = self._load()

    def _load(self) -> list[dict]:
        if not self.index_path.exists():
            return []
        try:
            value = json.loads(self.index_path.read_text(encoding="utf-8"))
            records = value.get("documents", []) if isinstance(value, dict) else []
            return [record for record in records if isinstance(record, dict)]
        except (OSError, json.JSONDecodeError):
            print(f"warning: could not read {self.index_path}; starting with an empty index", file=sys.stderr)
            return []

    def _save(self) -> None:
        temporary = self.index_path.with_suffix(".tmp")
        payload = json.dumps({"version": 1, "documents": self.records}, indent=2, ensure_ascii=False)
        temporary.write_text(payload + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.index_path)

    @staticmethod
    def public(record: dict) -> dict:
        result = {key: value for key, value in record.items() if key != "stored_name"}
        item_id = record["id"]
        result["file_url"] = f"/files/{item_id}"
        result["download_url"] = f"/files/{item_id}?download=1"
        return result

    def list(self) -> list[dict]:
        with self.lock:
            ordered = sorted(self.records, key=lambda item: item.get("received_at", ""), reverse=True)
            return [self.public(item) for item in ordered]

    def get(self, item_id: str) -> dict | None:
        with self.lock:
            return next((item for item in self.records if item.get("id") == item_id), None)

    def add_upload(self, files: list[dict], fields: dict[str, str]) -> tuple[list[dict], bool]:
        manifest_documents = parse_manifest(fields)
        prepared: list[dict] = []
        for index, upload in enumerate(files):
            payload = upload["payload"]
            if not payload:
                raise ValueError(f"{upload['filename']} is empty.")
            if len(payload) > MAX_FILE_BYTES:
                raise ValueError(f"{upload['filename']} exceeds the 100 MB per-file limit.")
            content_type, extension, kind = detect_file(payload)
            manifest_row = manifest_documents[index] if index < len(manifest_documents) else {}
            document_id = safe_text(
                manifest_row.get("document_id")
                or (fields.get("document_id") if len(files) == 1 else "")
                or uuid.uuid4().hex,
                160,
            )
            filename = safe_filename(
                manifest_row.get("filename") or upload["filename"],
                f"document-{index + 1}{extension}",
            )
            if Path(filename).suffix.lower() not in {extension, ".jpeg" if extension == ".jpg" else extension}:
                filename = f"{Path(filename).stem}{extension}"
            page_count_raw = manifest_row.get("page_count") or (fields.get("page_count") if len(files) == 1 else 1)
            try:
                page_count = max(1, min(int(page_count_raw), 10000))
            except (TypeError, ValueError):
                page_count = 1
            prepared.append(
                {
                    "upload": upload,
                    "manifest": manifest_row,
                    "document_id": document_id,
                    "filename": filename,
                    "content_type": content_type,
                    "extension": extension,
                    "kind": kind,
                    "page_count": page_count,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            )

        created_paths: list[Path] = []
        created_records: list[dict] = []
        created_any = False
        results: list[dict] = []
        with self.lock:
            try:
                for item in prepared:
                    existing = next(
                        (record for record in self.records if record.get("document_id") == item["document_id"]),
                        None,
                    )
                    if existing:
                        results.append(existing)
                        continue

                    library_id = uuid.uuid4().hex
                    stored_name = f"{library_id}{item['extension']}"
                    destination = self.files_dir / stored_name
                    destination.write_bytes(item["upload"]["payload"])
                    os.chmod(destination, 0o600)
                    created_paths.append(destination)
                    manifest_row = item["manifest"]
                    received_at = utc_now()
                    record = {
                        "id": library_id,
                        "document_id": item["document_id"],
                        "batch_id": safe_text(fields.get("batch_id"), 160),
                        "request_id": safe_text(fields.get("request_id"), 160),
                        "filename": item["filename"],
                        "stored_name": stored_name,
                        "content_type": item["content_type"],
                        "kind": item["kind"],
                        "size": len(item["upload"]["payload"]),
                        "page_count": item["page_count"],
                        "scanned_at": safe_text(manifest_row.get("scanned_at") or fields.get("scanned_at"), 80),
                        "received_at": received_at,
                        "source": safe_text(
                            manifest_row.get("source")
                            or manifest_row.get("scanner_name")
                            or fields.get("source")
                            or fields.get("scanner_name"),
                            160,
                        ),
                        "sha256": item["sha256"],
                    }
                    self.records.append(record)
                    created_records.append(record)
                    results.append(record)
                    created_any = True
                if created_any:
                    self._save()
            except Exception:
                for record in created_records:
                    if record in self.records:
                        self.records.remove(record)
                for path in created_paths:
                    try:
                        path.unlink()
                    except OSError:
                        pass
                raise
        return [self.public(record) for record in results], created_any

    def delete(self, item_id: str) -> bool:
        with self.lock:
            record = next((item for item in self.records if item.get("id") == item_id), None)
            if not record:
                return False
            self.records.remove(record)
            self._save()
            try:
                (self.files_dir / record["stored_name"]).unlink()
            except FileNotFoundError:
                pass
            return True


class DemoHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, store: LibraryStore, static_dir: Path, public_origin: str):
        super().__init__(address, handler)
        self.store = store
        self.static_dir = static_dir.resolve()
        self.public_origin = public_origin.rstrip("/")


class DemoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "TwainBridgeDemo/1.0"

    @property
    def demo_server(self) -> DemoHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args) -> None:
        sys.stderr.write(f"{self.log_date_time_string()} {self.address_string()} {format % args}\n")

    def send_bytes(
        self,
        status: int,
        payload: bytes,
        content_type: str,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Cache-Control", "no-store" if content_type.startswith("application/json") else "no-cache")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def send_json(self, status: int, value: object) -> None:
        self.send_bytes(status, json.dumps(value, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"success": False, "message": message})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        if path == "/":
            self.send_static("index.html")
        elif path == "/upload":
            self.send_static("upload.html")
        elif path == "/favicon.ico":
            self.send_bytes(HTTPStatus.NO_CONTENT, b"", "image/x-icon")
        elif path == "/assets/app.css":
            self.send_static("app.css")
        elif path == "/assets/app.js":
            self.send_static("app.js")
        elif path == "/assets/upload.js":
            self.send_static("upload.js")
        elif path in {"/api/health", "/health"}:
            self.send_json(HTTPStatus.OK, {"success": True, "status": "ok", "documents": len(self.demo_server.store.list())})
        elif path == "/api/documents":
            documents = self.demo_server.store.list()
            self.send_json(HTTPStatus.OK, {"success": True, "documents": documents, "count": len(documents)})
        elif path.startswith("/api/documents/"):
            self.send_document_json(path.rsplit("/", 1)[-1])
        elif path.startswith("/files/"):
            self.send_document_file(path.rsplit("/", 1)[-1], "download=1" in parsed.query)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found.")

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path not in {"/upload", "/api/upload"}:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found.")
            return
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length or "")
        except ValueError:
            self.send_error_json(HTTPStatus.LENGTH_REQUIRED, "A valid Content-Length header is required.")
            return
        if length <= 0:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "The request body is empty.")
            return
        if length > MAX_REQUEST_BYTES:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "The request exceeds the 150 MB limit.")
            return
        try:
            body = self.rfile.read(length)
            files, fields = parse_multipart(self.headers.get("Content-Type", ""), body)
            documents, created = self.demo_server.store.add_upload(files, fields)
        except ValueError as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
            return
        except OSError as exc:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, f"Could not store the upload: {exc}")
            return

        batch_id = safe_text(fields.get("batch_id"), 160)
        document_results = [
            {
                "document_id": item["document_id"],
                "success": True,
                "id": item["id"],
                "message": "Stored" if created else "Already stored",
            }
            for item in documents
        ]
        first = documents[0]
        self.send_json(
            HTTPStatus.CREATED if created else HTTPStatus.OK,
            {
                "success": True,
                "id": first["id"],
                "batch_id": batch_id,
                "message": f"Received {len(documents)} document{'s' if len(documents) != 1 else ''}.",
                "open_url": f"{self.demo_server.public_origin}/#document={quote(first['id'])}",
                "documents": document_results,
            },
        )

    def do_DELETE(self) -> None:
        path = urlparse(self.path).path
        if not path.startswith("/api/documents/"):
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found.")
            return
        item_id = path.rsplit("/", 1)[-1]
        if not ID_PATTERN.fullmatch(item_id) or not self.demo_server.store.delete(item_id):
            self.send_error_json(HTTPStatus.NOT_FOUND, "Document not found.")
            return
        self.send_json(HTTPStatus.OK, {"success": True})

    def send_static(self, filename: str) -> None:
        path = self.demo_server.static_dir / filename
        try:
            payload = path.read_bytes()
        except FileNotFoundError:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Static asset not found.")
            return
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type == "application/javascript":
            content_type += "; charset=utf-8"
        self.send_bytes(HTTPStatus.OK, payload, content_type)

    def send_document_json(self, item_id: str) -> None:
        if not ID_PATTERN.fullmatch(item_id):
            self.send_error_json(HTTPStatus.NOT_FOUND, "Document not found.")
            return
        record = self.demo_server.store.get(item_id)
        if not record:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Document not found.")
            return
        self.send_json(HTTPStatus.OK, {"success": True, "document": self.demo_server.store.public(record)})

    def send_document_file(self, item_id: str, download: bool) -> None:
        if not ID_PATTERN.fullmatch(item_id):
            self.send_error_json(HTTPStatus.NOT_FOUND, "Document not found.")
            return
        record = self.demo_server.store.get(item_id)
        if not record:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Document not found.")
            return
        file_path = self.demo_server.store.files_dir / record["stored_name"]
        try:
            file_size = file_path.stat().st_size
        except FileNotFoundError:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Stored file not found.")
            return

        start, end = 0, file_size - 1
        status = HTTPStatus.OK
        range_header = self.headers.get("Range", "")
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
            if not match:
                self.send_bytes(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, b"", record["content_type"], {"Content-Range": f"bytes */{file_size}"})
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), file_size - 1) if last else file_size - 1
            elif last:
                suffix = min(int(last), file_size)
                start = file_size - suffix
            if start > end or start >= file_size:
                self.send_bytes(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, b"", record["content_type"], {"Content-Range": f"bytes */{file_size}"})
                return
            status = HTTPStatus.PARTIAL_CONTENT

        with file_path.open("rb") as handle:
            handle.seek(start)
            payload = handle.read(end - start + 1)
        disposition = "attachment" if download else "inline"
        encoded_name = quote(record["filename"], safe="")
        headers = {
            "Accept-Ranges": "bytes",
            "Content-Disposition": f"{disposition}; filename*=UTF-8''{encoded_name}",
        }
        if status == HTTPStatus.PARTIAL_CONTENT:
            headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        self.send_bytes(status, payload, record["content_type"], headers)


def parse_args() -> argparse.Namespace:
    base_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run the TwainBridge demo upload receiver and document library.")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=9443, help="Listen port (default: 9443)")
    parser.add_argument("--data-dir", type=Path, default=base_dir / "data", help="Persistent storage directory")
    parser.add_argument("--cert", type=Path, help="TLS certificate in PEM format")
    parser.add_argument("--key", type=Path, help="TLS private key in PEM format")
    parser.add_argument("--http", action="store_true", help="Allow plain HTTP for browser-only development")
    parser.add_argument("--public-origin", help="Origin used in open_url responses, for example https://localhost:9443")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.http and not (args.cert and args.key):
        raise SystemExit("TLS is required for TwainBridge. Pass --cert and --key, or use --http for browser-only development.")
    if bool(args.cert) != bool(args.key):
        raise SystemExit("Pass both --cert and --key.")
    if not 1 <= args.port <= 65535:
        raise SystemExit("--port must be between 1 and 65535.")

    scheme = "http" if args.http else "https"
    origin_host = "localhost" if args.host in {"127.0.0.1", "0.0.0.0", "::", "::1"} else args.host
    public_origin = (args.public_origin or f"{scheme}://{origin_host}:{args.port}").rstrip("/")
    parsed_origin = urlparse(public_origin)
    if parsed_origin.scheme not in {"http", "https"} or not parsed_origin.netloc:
        raise SystemExit("--public-origin must be an absolute HTTP or HTTPS origin.")

    static_dir = Path(__file__).resolve().parent / "static"
    server = DemoHTTPServer((args.host, args.port), DemoHandler, LibraryStore(args.data_dir), static_dir, public_origin)
    if not args.http:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(args.cert), str(args.key))
        server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"TwainBridge Demo Receiver: {public_origin}")
    print(f"Upload endpoint:           {public_origin}/upload")
    print(f"Library data:              {args.data_dir.resolve()}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping receiver.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
