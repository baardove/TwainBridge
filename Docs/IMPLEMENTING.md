Below is a copy-paste implementation prompt designed around TwainBridge’s actual request and response behavior. Replace the values in `{{DOUBLE_BRACES}}` before handing it to Lovable.

```text
Build a production-ready HTTPS endpoint that receives scanned documents from a native macOS application named TwainBridge.

Do not only describe the endpoint. Implement the endpoint, database migrations, private file storage, authentication, validation, idempotency, structured responses, and automated tests.

Before implementation, confirm that the selected hosting platform supports the configured maximum multipart request size and execution duration. If its serverless functions cannot receive a {{MAX_BATCH_MB}} MB multipart upload reliably, place the endpoint on a suitable backend/container instead. Do not silently deploy an endpoint whose platform request limit is lower than the documented limit.

CONFIGURATION

Endpoint:
POST https://{{API_HOST}}/api/twainbridge/upload

Authentication:
{{AUTH_MODE: bearer token or custom X-Scanner-Key header}}

Recommended limits:
- Maximum documents per request: {{20}}
- Maximum bytes per document: {{50 MB}}
- Maximum total request size: {{150 MB}}
- Accepted file formats: PDF and JPEG
- Response size: less than 1 MB
- Request timeout compatibility: at least 60 seconds

Storage:
- Store documents in a private bucket named {{scanned-documents}}.
- Never make uploaded documents publicly accessible.
- Store application metadata in the project database.
- If the application is multi-tenant, scope every upload, document, idempotency record, and storage object to the authenticated tenant/account.

CUSTOM APPLICATION PARAMETERS

The endpoint must additionally accept these application-specific parameters:

Headers:
{{LIST REQUIRED CUSTOM HEADERS, OR "none"}}

Multipart form fields:
{{EXAMPLE:
- case_id: required UUID, batch scope
- document_type: required string, document scope
- note: optional string, document scope, maximum 500 characters
}}

Query parameters:
{{LIST ALLOWED QUERY PARAMETERS, OR "none"}}

Do not store arbitrary client fields automatically. Explicitly validate and map the configured fields.

1. TRANSPORT CONTRACT

Accept HTTPS requests using:

Content-Type: multipart/form-data; boundary=...

Do not expect JSON request bodies or base64-encoded documents.

The native client sets Content-Length. Reject an invalid, missing, zero, or excessive length before reading the full request where the framework permits it.

Do not redirect the upload unless absolutely necessary. The final endpoint must remain HTTPS.

TwainBridge may send either:

A. One document in one request
B. Multiple documents in one multipart request
C. A batch in which each document is sent as a separate request

The same endpoint must support all three forms.

2. AUTHENTICATION

Authenticate every real upload before processing its body where possible.

Support the selected authentication method:

Bearer-token example:
Authorization: Bearer {{SECRET}}

Custom-header example:
X-Scanner-Key: {{SECRET}}

Requirements:

- Compare secrets safely.
- Store only hashed API tokens where practical.
- Allow token rotation and revocation.
- Associate the token with the correct user, company, or tenant.
- Never accept credentials in query parameters or multipart form fields.
- Never log Authorization, X-Scanner-Key, or other secret-bearing headers.
- Return HTTP 401 when credentials are absent or invalid.
- Return HTTP 403 when credentials are valid but lack permission.
- Apply reasonable rate limiting by credential and, secondarily, IP address.
- CORS is not required for the native macOS client and must not be treated as authentication.

3. STANDARD MULTIPART FIELDS

A real upload can contain these transport fields:

- file: one or more PDF/JPEG file parts. The field name is configurable, but the recommended configuration is repeated parts named "file".
- batch_id: stable UUID identifying the logical batch.
- request_id: UUID identifying this particular network attempt.
- document_id: stable UUID identifying a document. Present for single-document and one-request-per-document uploads.
- document_index: zero-based position in the batch. Present for one-request-per-document uploads.
- page_count: positive integer. Present for single-document and one-request-per-document uploads.
- manifest: JSON string describing all documents in a multi-document request.
- Additional configured metadata fields.

The request also normally has these headers:

- Idempotency-Key: stable opaque identifier for the logical operation.
- X-Request-ID: the same attempt identifier represented by request_id.
- Authorization or the configured authentication header.

Treat Idempotency-Key as opaque. Do not require it to equal batch_id or document_id. Depending on TwainBridge’s request mode, it may represent either the batch or an individual document.

The request_id and X-Request-ID change for every network retry. They are for diagnostics only and must never be used as the permanent document identity.

The document_id and batch_id remain stable across retries and application restarts.

4. SINGLE-DOCUMENT REQUEST

A typical single-document request contains:

- One file part
- batch_id
- request_id
- document_id
- page_count
- Optional scanned_at
- Optional scanner_name
- Optional content_type
- Configured business metadata

Example:

POST /api/twainbridge/upload
Authorization header: configured bearer credential from your secret store
Idempotency-Key: <batch identifier generated by the client>
X-Request-ID: 6e81a06c-92dc-4664-b1ca-4a8cb83e08ae
Content-Type: multipart/form-data

file=@document.pdf;type=application/pdf
batch_id=8ac7cf62-f534-482f-aea1-9f39ab9b3ca7
request_id=6e81a06c-92dc-4664-b1ca-4a8cb83e08ae
document_id=c51af144-31dc-475b-b283-e65eb56c93f7
page_count=3
scanned_at=2026-07-17T14:30:00+01:00
scanner_name=EPSON DS-1660W

A successful response must be:

HTTP 200
Content-Type: application/json

{
  "success": true,
  "id": "remote-document-id",
  "message": "Document received",
  "open_url": "https://{{WEBAPP_HOST}}/documents/remote-document-id"
}

Rules:

- success must be a real JSON Boolean, not the string "true".
- id is the receiving application’s permanent record ID.
- message must be safe to display to the end user and should not contain secrets.
- open_url is optional.
- `open_url` must use HTTPS for public hosts. Local development receivers may return HTTP only for localhost, private/link-local addresses, or recognized LAN hostnames.
- Prefer a stable authenticated webapp page, not a public or short-lived storage-object URL.

5. MULTI-DOCUMENT REQUEST

TwainBridge can send several files in a single multipart request.

The recommended file convention is multiple file parts using the same field name:

file=@document-1.pdf
file=@document-2.pdf

The receiver should also tolerate these configurable conventions if feasible:

- files[] repeated
- file[0], file[1], etc.
- Custom names containing a document index or document UUID

The multipart request contains:

- batch_id
- request_id
- manifest
- One file part for every manifest document
- Batch-level application metadata

Example manifest:

{
  "batch_id": "65b659be-65d8-4531-b4e2-d50d7f29e04b",
  "documents": [
    {
      "document_id": "ebdfe463-a9a7-4bb4-855a-04ed6495eab8",
      "filename": "document-1.pdf",
      "page_count": 3,
      "scanned_at": "2026-07-17T14:30:00+01:00",
      "document_type": "invoice"
    },
    {
      "document_id": "ae9635d8-6ca9-40fb-907a-62eef98a3ea4",
      "filename": "document-2.pdf",
      "page_count": 1,
      "scanned_at": "2026-07-17T14:32:00+01:00",
      "document_type": "receipt"
    }
  ]
}

Validate that:

- batch_id is a valid UUID.
- manifest.batch_id matches the multipart batch_id.
- documents is a non-empty array.
- Every document_id is a valid UUID.
- Document IDs are unique within the manifest.
- page_count is a positive integer.
- The number of submitted files equals the number of manifest documents.
- Files are associated with manifest documents in multipart/manifest order when the field convention is repeated.
- Indexed file names use the corresponding manifest index.
- Filenames are treated as display metadata only, never as storage paths.
- The request does not exceed the document-count or byte limits.

For a fully successful batch, return:

{
  "success": true,
  "batch_id": "65b659be-65d8-4531-b4e2-d50d7f29e04b",
  "message": "Batch received",
  "documents": [
    {
      "document_id": "ebdfe463-a9a7-4bb4-855a-04ed6495eab8",
      "success": true,
      "id": "remote-101",
      "message": "Received"
    },
    {
      "document_id": "ae9635d8-6ca9-40fb-907a-62eef98a3ea4",
      "success": true,
      "id": "remote-102",
      "message": "Received"
    }
  ]
}

Every submitted document must have exactly one result with its exact document_id.

If a document result is omitted, TwainBridge will correctly treat that document as unconfirmed. Never return a successful batch response that silently omits documents.

6. PARTIAL SUCCESS

The endpoint must support a batch where some documents were stored and others were rejected.

For a processed request with partial document results, top-level success must remain true. Top-level success means “the batch request was understood and document-level results are authoritative”; it does not mean every document succeeded.

Example:

{
  "success": true,
  "batch_id": "65b659be-65d8-4531-b4e2-d50d7f29e04b",
  "message": "One document was rejected",
  "documents": [
    {
      "document_id": "ebdfe463-a9a7-4bb4-855a-04ed6495eab8",
      "success": true,
      "id": "remote-101",
      "message": "Received"
    },
    {
      "document_id": "ae9635d8-6ca9-40fb-907a-62eef98a3ea4",
      "success": false,
      "message": "The document type is not allowed for this case"
    }
  ]
}

Do not set top-level success to false merely because one document failed. Doing that prevents TwainBridge from safely applying the per-document results.

Use top-level success false when the complete request could not be processed authoritatively, for example invalid authentication, an unreadable manifest, or an invalid business context affecting the whole request.

7. IDEMPOTENCY AND DUPLICATE PREVENTION

Idempotency is mandatory because TwainBridge retries interrupted and transiently failed requests.

TwainBridge may retry:

- Connection failures and timeouts
- HTTP 408
- HTTP 425
- HTTP 429
- HTTP 5xx

The same document_id and batch_id will be used on retry, while request_id changes.

Use document_id as the ultimate duplicate-prevention identity, scoped to the authenticated tenant.

For each document, store:

- tenant/account ID
- document_id
- batch_id
- receiving application record ID
- SHA-256 content hash
- original filename as sanitized display metadata
- generated private storage key
- MIME type
- byte length
- page_count
- scanned_at when supplied
- processing/status state
- creation and update timestamps

Behavior:

- If the same document_id and identical content are submitted again after success, do not create another database record or storage object. Return the previously recorded successful result.
- If the same document_id is submitted with different content, return HTTP 409 with success false. Never overwrite the original document.
- If an identical batch request is replayed, return the already recorded results.
- After partial success, TwainBridge may retry only the failed subset using the original batch_id. Accept this subset and process only documents that do not already have confirmed success.
- Do not reject a legitimate failed-document subset merely because its body differs from the original full batch.
- If an already successful document is included in a retry with identical content, return its existing successful result.
- Never use request_id as an idempotency key.
- Do not cache transient 5xx responses as permanent idempotency results.
- Only report a document as successful after its file and required database state have been durably stored.

8. FILE VALIDATION AND STORAGE

For every file:

- Enforce the configured per-file and total-request limits.
- Accept application/pdf and image/jpeg.
- Check both the declared Content-Type and basic file signature.
- PDF should begin with a valid PDF signature.
- JPEG should have a valid JPEG signature.
- Reject unsupported or suspicious content with a document-level failure or HTTP 415.
- Calculate SHA-256 while receiving or before committing.
- Generate the storage path server-side.
- Never use the supplied filename directly as a filesystem or object-storage path.
- Sanitize filenames before displaying them.
- Do not execute, render, OCR, or parse uploaded files in the request process unless it is safe and required.
- If malware scanning or OCR is asynchronous, success may mean “durably accepted for processing.” Document this clearly.
- Clean up temporary or orphaned objects after failures.
- Never place the file contents in application logs, error trackers, analytics, or database text columns.

Recommended private object key:

{tenant_id}/{batch_id}/{document_id}/{generated-safe-name}.pdf

9. CONNECTION TEST

TwainBridge has a Test Connection action.

A connection test is identified by:

X-TwainBridge-Test: TwainBridge connection test

The test request:

- Is multipart/form-data.
- May contain no file.
- May contain a generated one-page PDF named twainbridge-test.pdf.
- May not contain Idempotency-Key, batch_id, document_id, or request_id unless those were explicitly configured as custom parameters.

For a connection test:

- Authenticate normally.
- Validate that the endpoint and configured parameters are usable.
- If a generated test PDF is present, validate it but do not create a real document record or retain the file.
- Do not require an idempotency key.
- Do not trigger OCR, workflows, notifications, or other business automation.
- Return standard JSON:

{
  "success": true,
  "message": "Connection successful"
}

This connection-test exception is essential. Do not reject it simply because no real document or idempotency key was supplied.

10. HTTP STATUS AND ERROR RESPONSES

Use these statuses consistently:

- 200 or 201: document stored and response is authoritative
- 202: durably accepted for asynchronous processing, if applicable
- 400: malformed multipart data, invalid UUID, or unreadable manifest
- 401: missing or invalid authentication
- 403: authenticated but unauthorized
- 409: document_id already exists with different content
- 413: file, batch, or request exceeds limits
- 415: unsupported file type
- 422: valid request rejected by business validation
- 425: temporarily too early to process
- 429: rate limited; include Retry-After
- 500/502/503/504: temporary server failure

All JSON error responses should use:

{
  "success": false,
  "message": "Safe, actionable explanation"
}

For a whole-request 4xx error, do not claim any document was stored unless the response contains authoritative document-level results.

Include Retry-After on 429 or temporary 503 responses when appropriate.

Keep response messages below 500 characters and remove control characters. Do not expose stack traces, database errors, storage paths, credentials, internal hostnames, or sensitive business data.

11. DATABASE DESIGN

Create database structures equivalent to:

scanner_upload_batches:
- tenant_id
- batch_id
- idempotency_key
- status
- created_at
- updated_at

scanner_documents:
- tenant_id
- document_id
- batch_id
- remote_id
- storage_key
- original_filename
- mime_type
- byte_count
- sha256
- page_count
- scanned_at
- scanner_name
- status
- failure_code
- created_at
- updated_at

scanner_upload_attempts:
- tenant_id
- request_id
- batch_id
- idempotency_key
- HTTP/result category
- received_at

Add uniqueness constraints at least on:

- tenant_id + document_id
- tenant_id + remote_id
- tenant_id + request_id where request_id is present

Do not store authorization headers, complete response bodies, or sensitive custom metadata in upload-attempt diagnostics.

If the webapp uses row-level security, ensure uploaded documents and records can only be accessed by authorized users in the same tenant.

12. OPEN URL

If a document page exists in the receiving webapp, return an optional open_url.

Requirements:

- HTTPS only.
- It should point to an authenticated application page, not directly to a public storage file.
- The receiving webapp must enforce authorization when the page is opened.
- If API_HOST and WEBAPP_HOST differ, tell the administrator to add WEBAPP_HOST to TwainBridge’s Allowed Redirect Hosts setting.
- Do not return open_url when there is no safe page to open.

13. PRIVACY AND OPERATIONAL SECURITY

- Use HTTPS with a publicly trusted certificate.
- Do not offer a “disable certificate validation” option.
- Keep the storage bucket private.
- Encrypt data at rest using the platform’s supported mechanisms.
- Redact authentication and sensitive custom fields from logs.
- Avoid logging original filenames unless explicitly required.
- Log request_id, batch_id, document_id, status category, byte count, and duration for diagnostics.
- Apply retention and deletion rules appropriate to the application.
- Provide an auditable deletion path for both the database record and private object.
- Protect any document-viewing and download routes with authorization.
- Do not expose a public list endpoint for received scans.

14. AUTOMATED ACCEPTANCE TESTS

Implement tests proving that:

1. A connection test with no file returns success and creates no document.
2. A connection test with twainbridge-test.pdf returns success and retains no file.
3. A valid single PDF is stored once and returns success true plus an id.
4. A valid JPEG is accepted.
5. Repeating the same document_id and identical file creates no duplicate.
6. Repeating the same document_id with different content returns 409.
7. A multi-document request returns exactly one result per document_id.
8. Files are paired with manifest entries in the correct order.
9. A partial batch returns top-level success true and document-level true/false results.
10. Retrying only the failed subset under the same batch_id works.
11. Missing authentication returns 401.
12. Invalid or unauthorized credentials return 401 or 403.
13. An invalid manifest returns 400 with success false.
14. An unsupported file returns 415 or a document-level failure.
15. Oversized documents and batches return 413.
16. A 429/503 test response includes Retry-After.
17. Responses use application/json and remain below 1 MB.
18. No test logs contain authorization tokens or document bytes.
19. open_url is HTTPS and requires application authorization.
20. A document is never reported successful before durable storage and database commit.

15. DELIVERABLES

Provide:

- The implemented upload endpoint
- Database migrations
- Private storage configuration
- Authentication/token setup
- Environment-variable documentation
- Automated tests
- A curl example for single-document upload
- A curl example for multi-document upload
- A curl example for the connection test
- A short administrator guide showing the exact TwainBridge destination settings
- Clear disclosure of the hosting platform’s actual request-size and timeout limits
```

Recommended TwainBridge profile:

- URL: `https://YOUR_API_HOST/api/twainbridge/upload`
- Method: `POST`
- File field: `file`
- File convention: `Repeated`
- Pages per document: `Multiple pages`
- Documents per send: `Multiple documents`
- Maximum documents: `20`
- Batch mode: `One multipart request`
- Include manifest: enabled
- Manifest field: `manifest`
- Receiver supports idempotency: enabled
- Idempotency header: `Idempotency-Key`
- Response mode: `Standard TwainBridge JSON`
- Success statuses: `200–299`
- Expected response type: `application/json`
- Empty response allowed: disabled
- Maximum response size: `1 MB`

Add these optional built-in form parameters:

- `scanned_at` → built-in `scanned_at`, document scope
- `scanner_name` → built-in `scanner_name`, document scope
- `content_type` → built-in `content_type`, document scope

Do not manually add `batch_id`, `request_id`, `document_id`, `document_index`, or `page_count`; TwainBridge already supplies those transport fields.
