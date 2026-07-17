import http.client
import importlib.util
import json
import tempfile
import threading
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "server.py"
SPEC = importlib.util.spec_from_file_location("demo_receiver", MODULE_PATH)
demo = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(demo)


def multipart(files, fields=None):
    boundary = "TwainBridgeBoundaryForTests"
    chunks = []
    for name, value in (fields or {}).items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                str(value).encode(),
                b"\r\n",
            ]
        )
    for field, filename, content_type, payload in files:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode(),
                f"Content-Type: {content_type}\r\n\r\n".encode(),
                payload,
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


class DemoReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        data_dir = Path(self.temporary.name) / "data"
        static_dir = Path(__file__).resolve().parent / "static"
        self.server = demo.DemoHTTPServer(
            ("127.0.0.1", 0),
            demo.DemoHandler,
            demo.LibraryStore(data_dir),
            static_dir,
            "http://127.0.0.1",
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        payload = response.read()
        response_headers = dict(response.getheaders())
        connection.close()
        return response.status, response_headers, payload

    def upload(self, files, fields=None):
        body, content_type = multipart(files, fields)
        status, headers, payload = self.request(
            "POST", "/upload", body, {"Content-Type": content_type, "Content-Length": str(len(body))}
        )
        return status, headers, json.loads(payload)

    def test_single_upload_lists_and_serves_document(self):
        jpeg = b"\xff\xd8\xff\xe0" + b"camera-image"
        status, _, response = self.upload(
            [("file", "webcam.jpg", "image/jpeg", jpeg)],
            {"document_id": "camera-001", "batch_id": "batch-001", "page_count": "1"},
        )
        self.assertEqual(status, 201)
        self.assertTrue(response["success"])
        self.assertEqual(response["documents"][0]["document_id"], "camera-001")
        self.assertIn("#document=", response["open_url"])

        status, _, body = self.request("GET", "/api/documents")
        listing = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual(listing["count"], 1)
        document = listing["documents"][0]
        self.assertEqual(document["kind"], "image")
        self.assertNotIn("stored_name", document)

        status, _, body = self.request("GET", document["file_url"])
        self.assertEqual(status, 200)
        self.assertEqual(body, jpeg)

    def test_duplicate_document_id_is_idempotent(self):
        pdf = b"%PDF-1.4\n%demo\n%%EOF"
        fields = {"document_id": "stable-document-id", "request_id": "request-1"}
        first_status, _, first = self.upload([("file", "scan.pdf", "application/pdf", pdf)], fields)
        second_status, _, second = self.upload([("file", "scan.pdf", "application/pdf", pdf)], fields)
        self.assertEqual(first_status, 201)
        self.assertEqual(second_status, 200)
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(len(self.server.store.list()), 1)

    def test_batch_manifest_maps_repeated_file_fields(self):
        manifest = json.dumps(
            {
                "batch_id": "batch-2",
                "documents": [
                    {"document_id": "doc-a", "filename": "First Scan.pdf", "page_count": 2},
                    {"document_id": "doc-b", "filename": "Desk Camera.jpg", "page_count": 1},
                ],
            }
        )
        files = [
            ("file", "upload-a.bin", "application/octet-stream", b"%PDF-1.7\n%%EOF"),
            ("file", "upload-b.bin", "application/octet-stream", b"\xff\xd8\xff\xe0photo"),
        ]
        status, _, response = self.upload(files, {"batch_id": "batch-2", "manifest": manifest})
        self.assertEqual(status, 201)
        self.assertEqual([item["document_id"] for item in response["documents"]], ["doc-a", "doc-b"])
        listed = self.server.store.list()
        self.assertEqual({item["filename"] for item in listed}, {"First Scan.pdf", "Desk Camera.jpg"})
        self.assertEqual({item["kind"] for item in listed}, {"pdf", "image"})

    def test_pdf_supports_byte_ranges(self):
        pdf = b"%PDF-1.4\n0123456789\n%%EOF"
        _, _, response = self.upload([("file", "scan.pdf", "application/pdf", pdf)])
        item_id = response["id"]
        status, headers, body = self.request("GET", f"/files/{item_id}", headers={"Range": "bytes=0-7"})
        self.assertEqual(status, 206)
        self.assertEqual(body, pdf[:8])
        self.assertEqual(headers["Content-Range"], f"bytes 0-7/{len(pdf)}")
        self.assertEqual(headers["Accept-Ranges"], "bytes")

    def test_delete_removes_index_and_file(self):
        _, _, response = self.upload([("file", "scan.pdf", "application/pdf", b"%PDF-1.4\n%%EOF")])
        item_id = response["id"]
        status, _, _ = self.request("DELETE", f"/api/documents/{item_id}")
        self.assertEqual(status, 200)
        self.assertEqual(self.server.store.list(), [])
        status, _, _ = self.request("GET", f"/files/{item_id}")
        self.assertEqual(status, 404)

    def test_rejects_unsupported_payload_without_partial_write(self):
        status, _, response = self.upload(
            [("file", "dangerous.svg", "image/svg+xml", b"<svg><script>alert(1)</script></svg>")]
        )
        self.assertEqual(status, 400)
        self.assertFalse(response["success"])
        self.assertEqual(self.server.store.list(), [])

    def test_library_page_and_health_are_available(self):
        status, headers, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["Content-Type"])
        self.assertIn(b"TwainBridge Library", body)
        status, _, body = self.request("GET", "/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

        status, headers, body = self.request("GET", "/upload")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["Content-Type"])
        self.assertIn(b"Manual upload", body)
        self.assertIn(b"twainbridge-test.pdf", body)


if __name__ == "__main__":
    unittest.main()
