# TwainBridge Demo Receiver

This is a small, dependency-free Python web server that receives TwainBridge uploads and presents them as a local document library. It accepts individual scans, multi-document batches, webcam captures, and manifest metadata. Images and PDFs open in a full-window viewer; PDFs use the browser's native PDF renderer.

The strict `ReferenceReceiver` remains the protocol/error-handling test fixture. This demo receiver is intended for people: it persists the uploaded files and gives you a useful visual destination while configuring or demonstrating TwainBridge.

## Quick start

Run the included launcher:

```bash
DemoReceiver/start.sh
```

Open [http://localhost:9080](http://localhost:9080) for the library. Open [http://localhost:9080/upload](http://localhost:9080/upload) for an interactive configuration guide and manual upload form. The same `/upload` address accepts TwainBridge uploads with `POST`.

TwainBridge permits HTTP for local-network destinations, including localhost, private LAN addresses, and local hostnames. Public destinations must use trusted HTTPS. Set `TWAINBRIDGE_DEMO_PORT` or `TWAINBRIDGE_DEMO_DATA_DIR` before running the script to override its port or storage directory.

To expose the demo on the LAN, bind it to the Mac's private address so the printed endpoint is immediately usable from other devices:

```bash
TWAINBRIDGE_DEMO_HOST=192.168.1.25 DemoReceiver/start.sh
```

The demo has no authentication. Only expose it on a trusted development network.

## Optional trusted local HTTPS

The simplest development certificate setup on macOS uses `mkcert`:

```bash
brew install mkcert
mkcert -install
mkdir -p .build/DemoReceiverTLS
mkcert \
  -cert-file .build/DemoReceiverTLS/localhost.pem \
  -key-file .build/DemoReceiverTLS/localhost-key.pem \
  localhost 127.0.0.1 ::1
python3 DemoReceiver/server.py \
  --cert .build/DemoReceiverTLS/localhost.pem \
  --key .build/DemoReceiverTLS/localhost-key.pem
```

Then open [https://localhost:9443](https://localhost:9443). Because `mkcert -install` adds its local certificate authority to the macOS trust store, TwainBridge can validate the connection normally.

Trusted HTTPS is recommended when the receiver leaves a development machine. Do not disable TLS validation or use an untrusted self-signed certificate. The application intentionally rejects plain HTTP for public destinations.

## Configure a TwainBridge destination

Create a destination with these settings:

| Setting | Value |
|---|---|
| URL | `http://localhost:9080/upload` from `start.sh`, or `https://localhost:9443/upload` with TLS |
| HTTP method | `POST` |
| File field name | `file` |
| Allowed formats | PDF, JPEG, and PNG |
| Multiple pages | Enabled if desired |
| Multiple documents | Enabled |
| Batch strategy | One multipart request |
| File naming convention | Repeated fields |
| Include manifest | Enabled |
| Manifest field | `manifest` |
| Response mapping | Standard JSON |
| Success status | `200...299` |
| Require JSON response | Enabled |
| Idempotency | Enabled |
| Authentication | None (local demo only) |

Optionally use **Test Connection** as a diagnostic after saving. TwainBridge automatically includes a generated `twainbridge-test.pdf`; no checkbox or test-file setting is required. A successful test is not required for Send. Scans and camera captures sent to this destination appear in the browser within five seconds. The response includes an `open_url` that links directly to the new document in the viewer.

The guide at `/upload` lists every accepted field and can generate a manifest from selected files. Its manual uploader sends the exact same multipart request accepted from TwainBridge, making it useful for checking the receiver independently of scanner or camera hardware.

## Upload contract

The receiver accepts `POST /upload` and `POST /api/upload` with `multipart/form-data`:

- One or more file parts. Repeated `file` fields are recommended, but any file field name is accepted.
- `batch_id` and `request_id` text fields.
- `document_id` and `page_count` for a single-document request.
- An optional JSON `manifest` field with a `documents` array. Manifest entries are matched to file parts by order.

Example:

```bash
curl https://localhost:9443/upload \
  --form 'file=@/path/to/scan.pdf;type=application/pdf' \
  --form 'batch_id=demo-batch' \
  --form 'document_id=demo-document-1' \
  --form 'page_count=2'
```

Only PDF, JPEG, and PNG payloads are stored. The server verifies file signatures instead of trusting the submitted MIME type or extension. SVG and HTML are rejected.

## Library behavior

- Files and a small JSON index persist under `DemoReceiver/data/` by default.
- The library supports search, format filters, sorting, direct-link hashes, downloads, and deletion.
- Image previews can be zoomed. PDFs support HTTP byte ranges and open in the browser's native viewer.
- Repeating an upload with the same `document_id` is idempotent and does not create a duplicate.
- Arbitrary form fields and authentication values are not written to the index.
- The data directory is created with owner-only permissions. This is still a development server: bind it only to a trusted interface.

Use a different storage location with `--data-dir /path/to/library`. If exposing the receiver through a reverse proxy, set the browser URL returned to TwainBridge with `--public-origin https://receiver.example.test`.

## Other endpoints

| Endpoint | Purpose |
|---|---|
| `GET /upload` | Configuration guide and manual upload form |
| `POST /upload` | TwainBridge multipart upload API |
| `POST /api/upload` | Alias for the multipart upload API |
| `GET /api/health` | Health and current item count |
| `GET /api/documents` | JSON library listing |
| `GET /api/documents/<id>` | One document's metadata |
| `GET /files/<id>` | Inline file response with byte-range support |
| `GET /files/<id>?download=1` | Download response |
| `DELETE /api/documents/<id>` | Remove the file and its metadata |

## Tests

```bash
python3 -m unittest discover -s DemoReceiver -p 'test_*.py'
```

The tests use a temporary library and cover single uploads, repeated file fields with a TwainBridge manifest, idempotent retry, range responses, deletion, payload validation, and the browser entry point.
