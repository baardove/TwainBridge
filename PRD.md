# TwainBridge Product Requirements Document

**Status:** Draft 5

**Product:** TwainBridge

**Platform:** macOS menu-bar application

**Initial release:** MVP

## 1. Product summary

TwainBridge is a lightweight macOS menu-bar utility that receives documents from a connected scanner, lets the user review the result, and securely posts the document to a configured webpage or web application.

The app normally runs quietly in the background. When a scan completes, it opens a compact, focused preview with the document, **Advanced…**, and **Send**. Last-used settings make the common path one-click. **Advanced…** reveals document, page, output, metadata, destination, export, and rescan controls when they are needed. TwainBridge uploads the document, reports the result, and returns to the background.

## 2. Problem

Many browser-based business systems cannot communicate directly with a local scanner. Users must scan to a file, find the file, open the target web application, and upload it manually. This is slow, error-prone, and difficult for users who scan documents repeatedly.

TwainBridge provides a controlled connection between local scanning hardware and a web application without requiring the web application to access the scanner directly.

## 3. Goals

- Reduce the path from completed scan to successful web upload to one review step and one click.
- Remain unobtrusive when no scan is in progress.
- Support single-page documents, multi-page documents, and batches containing multiple documents.
- Make upload status, failure, and recovery obvious.
- Keep scanned documents local except when the user explicitly sends them.
- Allow a non-technical user to configure and reuse one or more upload destinations.
- Recover safely from scanner, application, power, and network interruptions without losing completed pages or creating duplicate remote records.

## 4. Non-goals for the MVP

- A full document-management system or permanent local archive.
- OCR, data extraction, document classification, or automated routing.
- Image editing beyond rotate, reorder, and delete page.
- Scanner-driver installation or replacement.
- Direct TWAIN Classic, SANE, TWAIN Direct, or vendor-SDK integration unless the feasibility spike proves that a required pilot device cannot be supported through ImageCaptureCore or watched-folder import.
- Windows or Linux support.
- Fully unattended upload without a user confirmation.
- User accounts or cloud storage operated by TwainBridge.

## 5. Target users

### Primary user

An office worker who repeatedly scans invoices, contracts, identity documents, forms, or case material into an existing browser-based system.

### Administrator

An IT administrator or web-application owner who configures the scanner, upload destination, authentication method, retention rules, and optional metadata fields.

## 6. Core experience

1. TwainBridge launches at login and appears as a small scanner icon in the macOS menu bar.
2. A document arrives through either:
   - direct capture from a macOS-compatible scanner, using the user's selected source and scan settings; or
   - a configured watched folder populated by scanner vendor software.
3. The menu-bar icon animates or changes state while pages are being received.
4. When the scan completes, TwainBridge opens the preview window and becomes the foreground app.
5. The user reviews document tabs, page thumbnails, and the selected full-size page.
6. The user may rotate, reorder, or remove pages, and may add another document to the same batch when the destination permits it.
7. The user chooses a saved destination if more than one exists.
8. The user presses **Send**.
9. TwainBridge creates the configured output for each document, normally one PDF per document, and posts the complete batch using the destination's configured request mode.
10. The app shows success or an actionable error. On success, it retains the encrypted document in the local Document Library by default, or clears it after the short recovery window when library retention is disabled, then returns to the background.

## 7. Product requirements

### 7.0 First-run onboarding

The first launch must guide the user through a short, resumable setup:

1. Explain that TwainBridge encrypts scans locally and, by default, retains them in the Document Library after **Send** until the user removes them.
2. Request only the enabled permissions, including local-network access for network scanners and folder access for watched-folder import.
3. Discover available scanners and verify that the required macOS or vendor driver is available.
4. Let the user choose a scanner and perform an optional test scan that is discarded after confirmation.
5. Create or import an upload destination and optionally run **Test Connection** with no real scanned content.
6. Offer launch at login and background notifications.

The user may postpone scanner or destination setup, but the menu must show a clear incomplete-setup state and the action required. Missing-driver, no-scanner, no-destination, denied-permission, and offline states must each have a dedicated explanation and recovery action. For the DS-1660W, TwainBridge must identify a missing or incompatible Epson ICA driver and direct the user to [Epson's official support page](https://www.epson.eu/en_EU/support/sc/epson-workforce-ds-1660w/s/s1492); TwainBridge does not install the driver itself.

#### 7.0.1 Scanner provider scope

The MVP uses a provider abstraction with two enabled providers:

- **Native macOS:** ImageCaptureCore/ICA for USB and network scanners exposed by macOS. This is the primary provider and the required provider for the Epson DS-1660W.
- **Watched folder:** imports files created by Epson Scan 2, Epson Document Capture, or other vendor software.

AirScan/eSCL devices are supported in the MVP only when macOS exposes them through ImageCaptureCore. Direct eSCL, TWAIN Classic, TWAIN Direct, SANE, and vendor SDK providers are outside the MVP. A future provider must implement the same capability, progress, cancellation, error, and page-delivery contract without changing the preview or upload layers.

### 7.1 Menu-bar behavior

- The application must be usable without a persistent Dock window.
- The menu-bar icon must communicate these states: ready, scanning/importing, document ready, uploading, success, and error.
- Clicking the icon must expose:
  - **Scan New Document**
  - **Drafts**, including count and status when applicable
  - **Open Current Document**, when exactly one actionable draft exists
  - the most recent transfer status
  - scanner and destination selectors
  - **Settings**
  - **Quit TwainBridge**
- The app must support launch at login.
- The app must offer an optional, user-configurable system-wide scan shortcut. Invoking it uses the selected scanner and that scanner's saved defaults, creates a new draft, opens the workspace, and obeys scanner-busy, unsecured-page, disk-space, and 20-draft safeguards. Shortcut registration must not require Accessibility or Input Monitoring permission, and conflicts must be reported without replacing another application's shortcut.
- Closing the preview window must keep the app running unless the user explicitly quits.
- Choosing **Scan New Document** must open a compact scan setup view before acquisition begins. The user must not have to open the full Settings page to change the source, simplex/duplex mode, color, page size, or resolution for the next scan.
- If a scan or upload finishes while the preview is not frontmost, TwainBridge must show a native notification. Notification text must omit filenames and metadata by default.

### 7.2 Scan acquisition

- The app must support direct capture from scanners exposed through native macOS image-capture APIs.
- The app must support a watched-folder mode for devices that only scan through vendor software or do not expose physical scan-button events.
- The user must be able to start a scan from the menu-bar menu.
- If the device reports a scan-button event, TwainBridge must activate, use that scanner's saved default profile, begin acquisition when the event represents a scan request, and open preview after completion. Unsupported button behavior must fall back to the menu-bar scan action or watched folder.
- The user must be able to select a default scanner or watched folder.
- The app must detect disconnected, busy, unsupported, and permission-blocked scanner states and explain the next action.
- Before starting a direct scan, the interface must let the user select:
  - scanner device;
  - source: **Automatic**, **Flatbed**, or **Document Feeder**, when supported;
  - sides: **Single-sided** or **Duplex**, when the selected feeder supports duplex;
  - color mode: **Color**, **Grayscale**, or **Black & White**;
  - resolution, including 150, 200, 300, or 600 DPI when reported by the device;
  - page size: automatic detection or a device-supported paper size;
  - orientation: automatic, portrait, or landscape;
  - destination document: current document or new document, when adding to an open batch.
- Scan controls must be capability-driven. Unsupported values must not be selectable, and the app must not assume every scanner exposes the same resolutions, sources, paper sizes, or duplex behavior.
- Selecting **Flatbed** must disable feeder-only controls such as duplex and document-loaded state.
- Selecting **Document Feeder** must display whether paper is loaded when the device reports that state.
- Selecting **Automatic** must prefer a loaded document feeder and otherwise use the flatbed. The resolved source must be shown before scanning begins; if the device cannot report feeder-loaded state reliably, the app must ask rather than guess.
- Changing the scanner or source must refresh dependent capabilities without discarding unrelated choices.
- The app must remember the last successful scan settings per scanner and allow the user to restore the configured defaults.
- Hardware-button scans must use the saved default profile for that scanner because no pre-scan interface is available. The preview must clearly show which source and settings were used.
- Multiple pages from one scan session must be grouped into one draft document.
- While a batch is open, the user must be able to choose whether the next scan adds pages to the current document or starts a new document, subject to destination rules.
- The app must maintain explicit document boundaries; pages from separate documents must never be merged only because they were scanned close together.
- A device-capability spike is required before implementation because physical scan-button delivery varies by scanner model and driver. Watched-folder import is the required compatibility fallback.

#### 7.2.1 Scan setup interface

The scan setup view must use native macOS controls and show only settings relevant to the selected device and source. Its primary action is **Scan**. A secondary **Show Advanced Settings** disclosure may contain vendor-specific features reported by ImageCaptureCore.

For the Epson DS-1660W pilot device, the interface must expose and validate:

- **Flatbed** and **Document Feeder** sources;
- ADF single-sided and duplex modes;
- supported color modes;
- device-reported resolutions up to 600 DPI for the ADF and up to 1,200 DPI for the flatbed, without requiring every resolution to be shown as a preset;
- A4 and other device-reported paper sizes;
- feeder paper-loaded state when the Epson ICA driver supplies it;
- scan progress and cancellation.

The app must not promise Epson software-only functions such as OCR, barcode recognition, blank-page removal, or searchable PDF unless TwainBridge implements them or the ICA driver explicitly exposes them as usable vendor features.

#### 7.2.2 Interrupted scans and device errors

- TwainBridge must distinguish paper jam, double feed when reported, feeder empty, cover open, device busy, device disconnected, permission denied, unsupported setting, cancelled scan, and unknown device error.
- A partially transferred page must be discarded. Every fully transferred page must be preserved in the draft.
- When acquisition stops after one or more complete pages, the user must be offered **Keep Pages**, **Continue Scanning**, or **Discard**. **Continue Scanning** appends to the same document using the previous settings unless the user changes them.
- Cancelling before any page completes returns to scan setup. Cancelling after pages complete asks whether to keep or discard those pages.
- If the application terminates during acquisition, completed pages must be recovered as an interrupted draft on next launch. The app must never claim that an incomplete document was successfully scanned.
- Device removal must release the scan session promptly and keep the rest of the application usable.

#### 7.2.3 Watched-folder import

- The MVP accepts PDF, JPEG, PNG, single-page TIFF, and multi-page TIFF. Unsupported or corrupt files remain untouched and appear in a sanitized import error.
- Monitoring is non-recursive. Hidden files, package contents, temporary names, and files with unsupported extensions are ignored.
- A file is eligible only after its size and modification date remain unchanged across two checks at least three seconds apart and it can be opened for reading.
- TwainBridge copies an eligible file into its encrypted private draft store. It never modifies or deletes the source file in the MVP.
- Each PDF or TIFF becomes one document and retains its internal page order. Each JPEG or PNG becomes one single-page document.
- The default mode creates one draft per imported file. An optional five-second collection window may group several eligible files into one batch while preserving arrival order; it never merges image files into one document automatically.
- Duplicate import is prevented using a stored fingerprint of source identity, size, modification time, and content hash. A duplicate can be imported again only through an explicit **Import Again** action.
- If a draft or upload is already active, stable watched-folder files are queued and processed without interrupting the current foreground operation.
- Folder permission loss, unmounted volumes, and unavailable network shares must pause monitoring and show a recovery action without losing the configured folder bookmark.

### 7.3 Preview and document preparation

- The preview window must open in a focused send mode showing only:
  - a large fitted preview of the selected page
  - document and page count
  - minimal previous/next navigation when more than one page exists
  - a secondary **Advanced…** button
  - a primary **Send** or **Send All** button
  - compact blocking validation, authentication, progress, and cancellation feedback when applicable
- The focused view must reuse the last-selected destination, output settings, scan settings, and remembered posting values without asking again.
- **Advanced…** must reveal the complete workspace, which shows:
  - the documents in the current batch
  - page thumbnails in scan order
  - a large preview of the selected page
  - page count for the current document and document count for the batch
  - selected destination
  - scanner, source, sides, color mode, and resolution used for the selected document
  - output format and estimated file size
  - a primary **Send** button
- The complete workspace must provide **Simple View** to return to the focused send mode. Selecting a newly captured draft defaults back to focused mode.
- The selected page must support zoom in, zoom out, actual size, fit page, fit width, and panning.
- The user must be able to:
  - rotate a page clockwise or counter-clockwise
  - drag to reorder pages
  - delete a page with confirmation or an immediate undo option
  - add more pages to the current document
  - start a new document in the current batch
  - rename or remove a document from the batch
  - reorder documents when the configured posting mode preserves order
  - rescan and replace the document
  - cancel and discard the document
  - save a copy of one document or the complete batch
- **Add Pages**, **New Document**, and **Rescan** must reopen the scan setup view with the previous device and source selected, while allowing the user to change them before scanning.
- The MVP output formats per document are:
  - multi-page PDF, the default
  - JPEG for a single-page image
- The app must preserve scan resolution, physical page size, page order, rotation, and color mode when creating output.
- TwainBridge must never silently reduce document quality. If a document or batch exceeds a destination limit, **Send** is disabled and the user is offered **Compress Copy**, **Rescan at Lower Resolution**, **Save Copy**, or **Cancel**. The compression action must show an estimated output size and resulting quality before replacing the pending output.
- Generated PDF files must be standards-valid, contain one page per retained scan page, and use the physical dimensions reported by the scanner. JPEG is allowed only for a single-page document.
- Output filenames must be normalized, remove path separators and control characters, remain unique within a batch, use the correct extension, and be limited to 180 Unicode characters before the extension.
- Unsaved work must survive an accidental preview-window close and app restart, subject to the configured retention period.
- When a destination only permits single-page documents, adding a second page must either be blocked with an explanation or automatically create a new document, according to that destination's setting.
- **Send** becomes **Send All** when the batch contains more than one document. One click must submit the entire batch according to the configured request mode.
- **Send** or **Send All** must remain disabled while scanning, output generation, metadata validation, destination validation, or an upload is in progress.
- Discarding an unsent document or batch requires confirmation and states that the local copy will be removed. The confirmation may be suppressed only when the draft contains no completed page.
- Keyboard shortcuts must be provided for scan, add pages, rotate, delete page, save a copy, and send. Destructive shortcuts require confirmation or immediate undo.

#### 7.3.1 Draft queue and concurrency

TwainBridge must support multiple pending drafts. The menu-bar **Drafts** view shows drafts newest first with state, page count, document count, destination, and last-updated time.

Draft and transfer states are:

| State | Meaning |
|---|---|
| Acquiring | A direct scan is active. |
| Interrupted | Acquisition stopped after at least one completed page. |
| Ready | The draft can be reviewed and sent. |
| Needs information | Required metadata or destination configuration is incomplete. |
| Preparing | PDF/JPEG output is being generated or compressed. |
| Uploading | A network request is active. |
| Partially sent | Some documents succeeded and others remain actionable. |
| Failed | Acquisition, preparation, or upload failed and can be retried. |
| Sent | The remote result was confirmed; the encrypted content remains when stored in the Document Library, while recent-transfer history remains metadata-only. |

- The MVP permits one direct scanner acquisition at a time across the application. A second manual scan request opens after the active acquisition finishes; a hardware event received while busy is queued when the driver supports it or otherwise produces a notification to retry.
- Uploading does not block a new scan. A new scan creates another draft while the upload continues.
- Watched-folder imports may be processed in the background but must not modify the active preview selection.
- A draft being uploaded is read-only. Other drafts remain editable.
- The default maximum is 20 actionable drafts. At the limit, new manual scans are blocked and watched-folder imports pause with an actionable notification; no source file is deleted.
- Closing a window never discards a draft. Quitting while work is active asks for confirmation, cancels active device/network operations safely, persists their recoverable state, and restores it at next launch.
- After confirmed success, scanned payloads remain encrypted when the batch is marked for the Document Library. If library retention is disabled for that capture, payloads are deleted after the short recovery window. The separate recent-transfer record is always metadata-only.

### 7.4 Destination configuration

- A destination is a reusable upload profile with:
  - display name
  - HTTPS endpoint URL
  - HTTP method, with `POST` as the MVP default
  - upload field name, defaulting to `file`
  - page policy: single page only or multiple pages per document
  - maximum pages per document
  - batch policy: one document only or multiple documents per send
  - maximum documents per batch
  - batch request mode
  - accepted output format
  - maximum file size
  - request timeout
  - optional fixed form fields
  - optional success-page URL behavior
  - authentication configuration
- The MVP must support bearer-token and custom-header authentication.
- Secrets must be stored in the macOS Keychain and never shown in logs.
- Settings must include a **Test Connection** action that sends no scanned document.
- The app must prevent plain HTTP endpoints by default. An administrator-only override may be considered after the MVP.
- The user may save multiple destinations and choose a default.
- If only one destination exists, the preview should use it without requiring an extra selection step.
- Selecting or changing a destination must immediately revalidate document count, page count, output type, per-file size, total batch size, metadata, and request-mode constraints. The app must explain every conflict and keep **Send** disabled until resolved.
- Changing the destination host while an unsent draft is open requires confirmation that identifies the old and new hosts.
- Destination profiles may be exported and imported as versioned JSON. Exports must omit secrets and values marked sensitive. An imported profile that requires secrets remains disabled until they are re-entered and the user enables the valid profile; **Test Connection** remains optional. Unknown profile versions or unsupported settings must be rejected without partially importing the profile.

The destination editor must expose a **Documents & pages** section with these controls:

| Setting | Options | Default |
|---|---|---|
| Pages per document | Single page / Multiple pages | Multiple pages |
| When another page is scanned in single-page mode | Start a new document / Ask / Reject | Start a new document |
| Maximum pages per document | Positive integer or no configured limit | No configured limit |
| Documents per send | One document / Multiple documents | One document |
| Maximum documents per batch | Positive integer | 20 |
| Batch request mode | One multipart request / One request per document | One multipart request |
| Partial success behavior | Keep only failed documents / Keep the complete batch | Keep only failed documents |

For **One multipart request**, the settings page must additionally define:

- file field convention: repeated field name such as `files[]`, indexed names such as `files[0]`, or a configurable field name per document;
- whether a JSON batch manifest is included and its form field name;
- whether document order is significant;
- maximum total batch size.

For **One request per document**, **Send All** remains one user action, but TwainBridge sends a separate HTTP request for each document. The settings page must define whether requests run sequentially or with limited concurrency. Each result must be tracked separately so successful documents are not resent unnecessarily.

The destination editor must also expose a **Request** section for defining the target and posting parameters:

| Setting | Requirement |
|---|---|
| Destination URL | Required HTTPS URL for public hosts. HTTP is allowed only for localhost, private/link-local IP ranges, and recognized local-network hostnames. The URL may contain approved placeholders but may not contain secret values. |
| HTTP method | `POST` for MVP; the model should allow future `PUT` support. |
| Body encoding | `multipart/form-data` for MVP. Raw binary and JSON-with-base64 are future options. |
| File parameter | Configurable field name and filename pattern. |
| Headers | Add, edit, reorder, enable, or disable named headers. |
| Form parameters | Add, edit, reorder, enable, or disable multipart text fields. |
| Query parameters | Optional named URL parameters; secrets are disallowed here. |
| Timeout and limits | Request timeout, maximum file size, and maximum total batch size. |

Each configurable header, form parameter, or query parameter must contain:

- parameter name;
- location: header, form body, or query string;
- value source: fixed value, built-in scan value, generated value, or value entered before sending;
- scope: request, batch, or individual document;
- data type: text, integer, decimal, Boolean, date, date-time, or enumerated choice;
- value or built-in mapping;
- required or optional state;
- sensitive state, where supported; sensitive fixed values are stored in Keychain;
- optional user-facing label, help text, and default value for parameters entered before sending;
- optional allowed values, minimum, maximum, maximum length, and validation expression;
- whether a non-sensitive user-entered value may be remembered for this destination.

Scope behavior is deterministic:

- **Request** values are emitted once per HTTP request.
- **Batch** values are emitted once in a one-request batch and are repeated on each request in one-request-per-document mode.
- **Document** values are emitted on that document's request in one-request-per-document mode and are stored under the matching `document_id` in the manifest for a one-request batch.

Supported built-in values for the MVP are `document_id`, `batch_id`, `filename`, `page_count`, `document_count`, `scanned_at`, `scanner_name`, and `content_type`. A per-document built-in used in a single multipart batch belongs in the manifest rather than being reduced to one ambiguous form value.

Before sending, TwainBridge must render a metadata form generated from these parameters. Batch fields are shown once; document fields are shown for each document with clear document identity. Validation occurs while editing and on destination change. Sensitive entered values are masked, never written to draft metadata or logs, and are remembered only when explicitly saved to Keychain.

The settings page must show a sanitized request preview containing the final URL, header names, body field names, and placeholder values. It must flag duplicate parameter names, invalid URLs, unsupported combinations, missing file mapping, secret values placed in the URL, and page or batch limits that conflict with the selected request mode.

Reserved transport headers such as `Host`, `Content-Length`, `Transfer-Encoding`, and `Connection` cannot be configured manually. Header and parameter names or values containing control characters or line breaks must be rejected. `Authorization` and other sensitive headers are permitted only through the secret-aware authentication or parameter editor.

**Test Connection** is an optional diagnostic and must never use a real scanned document. Every test automatically includes a generated one-page PDF clearly named `twainbridge-test.pdf`; the user is not asked whether to include it. Send must not depend on the test having been run or succeeded. The result must show the HTTP status and a sanitized response summary, and a failed test must not disable the destination.

#### 7.4.1 Response mapping

A destination must select one response mode:

- **Standard TwainBridge JSON:** uses the response fields documented in section 7.5.
- **Status only:** any configured success status is sufficient and the body is ignored.
- **Custom JSON:** the destination defines JSON paths for overall success, message, remote document ID, browser URL, and, when batching, the per-document results array and document identifier.

Response settings must include accepted success status codes, default `200...299`; whether an empty body is permitted; expected content type; maximum response body size, default 1 MB; and whether a missing optional field is acceptable. A required JSON response that is malformed, oversized, or does not satisfy its mapping is an unconfirmed result rather than success. Response text shown to the user is stripped of control characters and limited to 500 characters.

### 7.5 Upload contract

The default single-document integration contract is an HTTPS `multipart/form-data` request:

| Field | Type | Required | Description |
|---|---|---:|---|
| `file` | File | Yes | PDF or JPEG document; field name is configurable. |
| `document_id` | String | Yes | UUID generated for the local scan session and retained across retries. |
| `page_count` | Integer | Yes | Number of pages in the document. |
| `scanned_at` | String | Yes | ISO 8601 timestamp with timezone. |
| `scanner_name` | String | No | Local device name when available. |
| Configured metadata | String | No | Fixed or user-entered fields defined by the destination. |

Authentication is sent in request headers and not in form fields or query parameters.

The receiving application should return JSON:

```json
{
  "success": true,
  "id": "remote-document-id",
  "message": "Document received",
  "open_url": "https://example.test/documents/remote-document-id"
}
```

- A configured success status, default any `2xx`, is treated as transport success but is not a confirmed application success until the selected response mapping also passes.
- If a JSON `success` value is present and is `false`, the operation is treated as a failure.
- `message` is shown to the user after sensitive content is excluded.
- If `open_url` is present, the success view may offer **Open in Browser**. Automatic opening is a per-destination option and is off by default.
- Uploads must include the same `document_id` on every retry so the receiver can prevent duplicate records.
- The default request includes an `Idempotency-Key` header: `document_id` for a single-document request and `batch_id` for a one-request batch. The header name is configurable for receivers that use another convention.

For a multi-document batch sent in one multipart request, the default contract is:

| Field | Type | Required | Description |
|---|---|---:|---|
| `files[]` | File, repeated | Yes | One PDF or JPEG for each document, in batch order; field convention is configurable. |
| `batch_id` | String | Yes | UUID generated for the batch and retained across retries. |
| `manifest` | JSON string | Yes | Ordered document metadata containing each `document_id`, filename, page count, and scan timestamp. |
| Configured metadata | String | No | Batch-level fixed or user-entered fields defined by the destination. |

Example manifest:

```json
{
  "batch_id": "65b659be-65d8-4531-b4e2-d50d7f29e04b",
  "documents": [
    {
      "document_id": "ebdfe463-a9a7-4bb4-855a-04ed6495eab8",
      "filename": "document-1.pdf",
      "page_count": 3,
      "scanned_at": "2026-07-17T14:30:00+01:00"
    },
    {
      "document_id": "ae9635d8-6ca9-40fb-907a-62eef98a3ea4",
      "filename": "document-2.pdf",
      "page_count": 1,
      "scanned_at": "2026-07-17T14:32:00+01:00"
    }
  ]
}
```

The receiver should return one result per document so TwainBridge can represent full or partial success:

```json
{
  "success": true,
  "batch_id": "65b659be-65d8-4531-b4e2-d50d7f29e04b",
  "documents": [
    { "document_id": "ebdfe463-a9a7-4bb4-855a-04ed6495eab8", "success": true, "id": "remote-101" },
    { "document_id": "ae9635d8-6ca9-40fb-907a-62eef98a3ea4", "success": true, "id": "remote-102" }
  ]
}
```

The same `batch_id` and per-document `document_id` values must be reused on retry. When the server cannot report per-document results, a failed batch is treated as wholly unconfirmed and retried as a complete batch.

For **One request per document**, each request must also include the shared `batch_id`, its own stable `document_id`, and its zero-based `document_index`. The app must retain a separate response and retry state for each request.

#### 7.5.1 Identifier lifecycle and idempotency

- A `document_id` is created when a new document is created and persists through page addition, removal, reordering, rotation, compression, application restart, and retry before confirmed upload.
- A `batch_id` is created when the first document enters a batch and persists through document reordering and partial retry.
- Changing a draft to a different destination host creates a new `batch_id`; document IDs remain stable because they identify the local documents.
- A document with confirmed remote success is immutable in transfer history. **Send Again**, replacing its content, or moving it into another outbound batch creates a new local document and new `document_id`.
- A partially successful batch keeps the original IDs for failed or unconfirmed documents. Successful documents are read-only and are never resent unless the user explicitly creates a new copy.
- Each destination has a **Receiver supports idempotency** setting. It defaults on for the standard contract. When off, TwainBridge must warn that ambiguous retries can create duplicates and must not automatically retry after request transmission may have completed.
- A stable client-generated `request_id` is added to every individual attempt for diagnostics, while `document_id` and `batch_id` represent the logical operation across attempts.

### 7.6 Upload states and recovery

- The user must see upload progress for larger files.
- The **Send** button must not initiate duplicate concurrent uploads.
- The **Send All** button must show both overall batch progress and the status of each document.
- On a network or server failure, the document must remain available with **Retry** and **Save As…** actions.
- The user may cancel an active upload. Cancellation stops the current attempt, preserves the draft, and returns it to **Ready** without marking it as remotely failed or successful.
- When receiver idempotency is enabled, TwainBridge performs at most three automatic retries after the initial attempt, with delays of 2, 10, and 30 seconds. It retries connection failures, timeouts, `408`, `425`, `429`, and `5xx`; it does not retry other `4xx` responses.
- A valid `Retry-After` value replaces the normal delay up to a maximum of five minutes. Longer values pause the draft and require manual confirmation.
- While the Mac is offline, the draft enters **Waiting for network** without consuming a retry attempt. It resumes when connectivity returns unless the user cancelled or the retention period expired.
- Multipart uploads are not resumable in the MVP. A retry restarts the affected request from byte zero with the same logical identifiers and a new `request_id`.
- If the Mac sleeps, quits, restarts, or changes network during upload, the current request becomes interrupted. On recovery it retries automatically only when receiver idempotency is enabled; otherwise the user receives an unconfirmed-status warning.
- Uploads must use the system proxy and system certificate trust store. Invalid, expired, or untrusted TLS certificates cannot be bypassed. Client-certificate authentication is outside the MVP.
- Authentication errors must direct the user to destination settings without deleting the document.
- If the server response is ambiguous, TwainBridge must report that the upload could not be confirmed. It retries with the same logical identifiers only when receiver idempotency is enabled; otherwise retry requires explicit user confirmation.
- After partial success, only failed or unconfirmed documents may be retried when the server provides reliable per-document results.
- The user must be able to copy a sanitized diagnostic summary.
- Retry state, attempt count, timestamps, status codes, `request_id`, `document_id`, and `batch_id` must persist without storing request secrets or response bodies.
- Failed or waiting uploads remain actionable until the configured draft retention period expires. Before expiration, TwainBridge warns the user and offers **Retry**, **Save Copy**, or **Discard**.

### 7.7 Settings

Settings must contain:

- **Scanner defaults:** default device, source, sides, color mode, resolution, page size, orientation, and watched-folder configuration. These are defaults for new and hardware-button scans; the user can override them in the scan setup view. A destination may optionally select a scanner preset, but a per-scan user override remains possible.
- **Global scan shortcut:** enable or disable the shortcut; select a supported letter, number, or function key and Command, Option, Control, or Shift modifiers; show the effective shortcut and any registration conflict.
- **Webcam capture:** select a built-in, USB, or Continuity Camera; open a live preview before taking a single document photo; request macOS camera permission only when needed; import the result into the same encrypted draft pipeline; and configure a separate global webcam shortcut with independent conflict feedback.
- **Destinations:** create, edit, delete, test, and set default; configure URL, HTTP method, request encoding, authentication, posting parameters, page policy, and multi-document batch behavior.
- **Document:** default format, PDF quality, default filename pattern, file-size behavior.
- **Privacy:** whether new captures are kept in the encrypted Document Library, current library item/storage totals, actionable-draft retention period, and clear temporary documents now.
- **General:** launch at login, privacy-preserving notifications, open browser after send, automatic update checks, and diagnostics.
- **Profiles:** export or import versioned destination and scan profiles without secrets.

All operational choices are persistent by default. TwainBridge restores the last selected scanner, source, sides, color mode, resolution, page size, orientation, webcam, destination, output format, compression, preview fit/zoom, connection-test options, and both global shortcuts. A new scanner or webcam acquisition starts with the last-used destination and document output choices. Non-sensitive user-entered posting values default to reuse for that destination; sensitive values may reuse only through Keychain-backed storage. A parameter can explicitly opt out when its value is intentionally different for every document. Safety confirmations for destination-host changes, ambiguous non-idempotent retries, destructive deletion, and exceptional size/policy conflicts are never remembered or bypassed.

### 7.8 Document Library

- New scanner captures, webcam photos, and watched-folder imports are retained in the encrypted local Document Library by default. This setting is persistent and applies automatically to future captures without asking during each workflow.
- Existing encrypted drafts created before the library flag was introduced migrate into the library so an upgrade does not silently delete previously captured content.
- The library is a dedicated window reachable directly from the menu bar. It shows newest items first with thumbnail, document name, source, capture time, document/page counts, send state, destination, and approximate local size.
- The user can search by document name or status and filter by scanner, webcam, or watched-folder source. A batch containing more than one source appears in every applicable source filter.
- Opening an item restores it in the normal workspace. Sent items remain read-only, but the user can preview them, export one or all documents, and choose **Send Again** to create a fully independent draft with new logical identifiers.
- Removing a sent library item permanently deletes its encrypted local manifest and payloads after confirmation. It does not delete any remote copy. Removing an actionable item from the library leaves it as a normal draft subject to draft retention so pending work is not accidentally lost.
- Library items do not expire through temporary-draft or short post-success cleanup. The UI shows their aggregate approximate storage use and supports item-by-item removal. Automatic quota eviction is not allowed in the MVP.
- Library content uses the same authenticated encrypted manifest and page storage as drafts. Preview and export may materialize private short-lived plaintext files only through the existing protected temporary-output lifecycle.
- Turning off **Keep new captures in the encrypted Document Library** affects future new batches. It does not retroactively delete existing library items or change a batch being appended.
- Document Library storage and metadata-only Recent Transfers are independent. Clearing transfer history does not remove library documents, and removing a library item does not remove transfer metadata.

### 7.9 Recent transfers and diagnostics

- TwainBridge keeps a metadata-only list of the 50 most recent transfer operations for at most 30 days. It contains timestamps, destination display name and host, document and page counts, result state, remote IDs, logical identifiers, and sanitized error category. It contains no document payload, thumbnail, entered sensitive metadata, token, or full response body.
- The user may clear recent-transfer metadata immediately and may disable history entirely.
- **Open in Browser** is available from history only when the stored URL passed the destination's URL policy.
- **Export Support Bundle** creates a user-reviewed text or JSON bundle containing app and macOS versions, architecture, installed scanner-provider and driver versions, reported device capabilities, recent sanitized error categories, and correlation IDs. It never includes scan content, filenames, endpoint secrets, entered metadata values, full request URLs with query strings, or response bodies.

## 8. Interaction and visual direction

### Visual thesis

A calm, native macOS utility with paper-white document surfaces, graphite controls, and one clear blue action color.

### Content plan

The menu bar provides status and quick actions; the preview is the primary workspace; settings hold device and destination configuration; success and error messages remain compact and actionable.

### Interaction thesis

- The menu-bar icon subtly changes as a page arrives, then gains a small ready indicator.
- The preview window enters only after a document is ready; page thumbnails appear progressively during multi-page capture.
- Sending transitions the primary button into inline progress, then a short success confirmation before the app returns to the background.

The interface must follow macOS conventions, support keyboard navigation, expose accessibility labels, and remain usable with VoiceOver and increased contrast.
- The MVP is English-first. All user-facing strings must be externalized so localization can be added without changing product logic.

## 9. Privacy and security

- Scanned documents must remain encrypted on the Mac while they are drafts and, when library retention is enabled, after the user presses **Send**.
- Documents must be stored in the app's private data container and encrypted at rest using authenticated encryption. This includes page payloads and draft manifests containing filenames, scanner details, and posting metadata. The installation key is generated locally, stored in macOS Keychain, and never exported with profiles or diagnostics. A legacy plaintext manifest, if encountered during an upgrade, must be migrated atomically to authenticated encrypted storage and removed after the encrypted replacement is committed.
- ImageCaptureCore and watched-folder inputs may exist briefly as plaintext only inside a private, randomly named staging directory. TwainBridge must encrypt completed pages promptly, exclude staging from diagnostics and backups where supported, and remove plaintext staging files after import, cancellation, crash recovery, or upload preparation.
- Temporary files must use non-guessable names and must not be written to a shared desktop or downloads folder unless the user chooses **Save As…**.
- Destination credentials must be stored in Keychain.
- Only HTTPS destinations are permitted by default.
- Logs must not contain document contents, authentication secrets, full response bodies, or fixed metadata values marked sensitive.
- The default retention behavior is to keep captures in the encrypted Document Library after confirmed upload. When the user disables library retention for new captures, those temporary payloads are deleted after a short delayed cleanup window that supports crash recovery.
- Drafts and failed uploads are retained for a configurable period, default 24 hours, then securely removed where the filesystem permits.
- The app must ask for only the device, folder, notification, and network permissions necessary for enabled features.
- Destination redirects must not forward authentication headers to another host.
- Redirects are limited to five hops. A redirect to another host is rejected unless that host is explicitly allowlisted in the destination, and sensitive headers are never forwarded across hosts.
- Server-provided `open_url` values must use HTTPS, or approved local-network HTTP, and match the destination host or an explicit allowlist. The first automatic-open request for a host requires confirmation.
- Destination URLs are visible by host in the Advanced workspace. A user-initiated destination edit is permitted in the MVP; centrally managed locked profiles are deferred to managed deployment.
- Plain HTTP, invalid certificate bypass, secret query parameters, and arbitrary trust exceptions are not available in the MVP.
- Deleting a draft removes the encryption-wrapped payload and associated key material or references. The UI must not claim guaranteed physical-sector erasure on SSD storage.

## 10. Non-functional requirements

- Ready-state memory use must remain below 150 MB on a representative supported Mac.
- The app must become ready within 3 seconds after login on a representative supported Mac.
- A completed scan must appear in preview within 2 seconds after its file or device transfer is complete.
- The interface must stay responsive while assembling or uploading a 100 MB document.
- The MVP must support at least 100 pages or 100 MB per document, subject to destination limits.
- Upload timeout and maximum size must be configurable per destination.
- The app must recover an in-progress draft after a crash or restart.
- The supported macOS baseline is defined in section 10.1 and must be revisited during each major macOS release cycle.
- All user-facing errors must state what happened, whether the document is safe, and what the user can do next.
- Draft encryption, preview generation, PDF assembly, hashing, and upload must be streamed or bounded so a 100 MB document is not duplicated fully in memory.
- Draft state changes and page imports must be transactional: after a crash the app restores either the previous valid state or the complete new state, never a half-written manifest.
- Before acquisition, import, compression, or output generation, TwainBridge must check available disk space. It must preserve at least 500 MB of system free-space headroom in addition to the estimated operation requirement, pause watched-folder intake when space is insufficient, and never delete another draft automatically to make room.

### 10.1 Distribution and macOS integration

- The MVP is distributed directly as a universal ARM64/x86_64 application signed with Developer ID, notarized by Apple, and built with Hardened Runtime. Mac App Store distribution is not an MVP requirement.
- App Sandbox is disabled for the MVP to reduce compatibility risk with third-party ICA device modules. The feasibility spike must verify whether sandboxing can be enabled later without breaking supported scanners.
- Launch at login uses the current macOS service-management API and is always user-controlled.
- Updates are delivered through a signed HTTPS update feed. Update packages must be signature-verified before installation, and automatic installation is off while scanning or uploading.
- TwainBridge must provide purpose strings and onboarding for local-network, folder, and notification access. If a future sandboxed build is shipped on macOS 14 or later, it must include the required USB device entitlement.
- The MVP support baseline is macOS 15 and macOS 26 on supported Intel and Apple Silicon Macs. The release may narrow Intel coverage if a supported macOS/scanner combination cannot pass the matrix.
- The Epson DS-1660W pilot baseline is Epson ICA/Epson Scan 2 version 6.7.84.0 or a later version that passes compatibility testing. Older driver versions are reported as unverified rather than silently accepted as supported.
- The app installs no kernel extension, system extension, scanner driver, privileged helper, or root-owned daemon.

### 10.2 Required compatibility matrix

Before release, the following combinations must be tested and recorded:

| Dimension | Required coverage |
|---|---|
| macOS | 15 and 26, latest security update available during testing |
| Architecture | Apple Silicon; Intel where supported by the selected macOS version |
| DS-1660W connection | Direct USB, infrastructure Wi-Fi, and Wi-Fi Direct discovery where practical |
| Source | Flatbed and ADF |
| ADF | Single-sided, duplex, empty feeder, jam recovery, cancellation, and 50-page job |
| App lifecycle | Login launch, preview closed, sleep/wake, quit/relaunch, crash recovery |
| Network | Online, offline before send, loss during upload, system proxy, TLS failure, `429`, and `5xx` |
| Destination | Single document, multi-document single request, per-document requests, partial success, malformed response, and size-limit rejection |
| Watched folder | Local folder, unavailable volume, partial file, duplicate file, corrupt file, multipage PDF, and multipage TIFF |

A release compatibility note must list validated scanner models, driver versions, macOS versions, architectures, connection modes, button behavior, and known limitations.

## 11. MVP acceptance criteria

The MVP is complete when:

1. First-run onboarding can complete scanner discovery, optional test scan, destination setup, test connection, notification choice, and launch-at-login choice, and can recover from missing driver, denied permission, no scanner, no destination, and offline states.
2. TwainBridge launches at login, remains usable from the menu bar without a persistent Dock window, and shows actionable draft and transfer counts.
3. The shipped MVP contains the ImageCaptureCore/ICA and watched-folder providers and does not require TWAIN Classic or SANE.
4. Before scanning, a user can select the scanner, flatbed or feeder, simplex or duplex, color mode, supported resolution, page size, and orientation without opening Settings.
5. Choosing flatbed disables duplex and other feeder-only controls; choosing the feeder exposes only capabilities reported for the feeder.
6. On an Epson DS-1660W with a validated Epson ICA driver, the app can select flatbed or ADF, acquire a multi-page feeder scan, acquire a duplex scan in correct page order, show progress, and cancel safely over every connection mode marked supported.
7. A jam, feeder-empty condition, disconnect, cancellation, or crash after completed pages preserves those pages and offers the documented keep, continue, and discard choices without retaining a partial page.
8. Watched-folder import waits for file stability, imports every supported format correctly, preserves source files, rejects corrupt input safely, prevents accidental duplicate import, and recovers after folder access is lost.
9. A new scan during upload creates a separate draft; a second acquisition is queued or rejected as documented; and the 20-draft limit never causes source-file deletion or silent loss.
10. The draft list restores accurate state after normal quit, forced quit, sleep/wake, and application crash.
11. A completed scan opens in focused mode with a fitted preview, counts, optional page navigation, **Advanced…**, and **Send**. Advanced mode provides accurate document boundaries, source settings, zoom and pan controls, and estimated output size.
12. A user can rotate, reorder, remove, add, rescan, save a copy, and discard pages or documents with the required confirmation or undo behavior.
13. TwainBridge produces valid multi-page PDF and single-page JPEG output with correct page dimensions, rotation, order, unique safe filenames, and bounded memory use.
14. An oversized document disables send and offers compression, lower-resolution rescan, save copy, and cancellation without silently changing quality.
15. A user can create a batch with at least two documents, review its boundaries, enter batch-level and document-level metadata, and submit it with one **Send All** action.
16. A destination can independently allow or prohibit multiple pages per document and multiple documents per send, and changing destination revalidates every affected limit and required field.
17. A user can configure an HTTPS multipart destination with URL, file mapping, typed and validated posting parameters, response mapping, and a Keychain-stored bearer token or custom sensitive header.
18. Exported destination profiles contain no secrets, and importing an unsupported or invalid profile leaves existing configuration unchanged.
19. **Test Connection** distinguishes success, authentication failure, invalid response, TLS failure, server failure, and unreachable host without sending a real scan.
20. Standard JSON, status-only, and custom JSON response modes correctly distinguish confirmed success, application failure, partial success, and unconfirmed response.
21. Single-document, one-request multipart batch, and one-request-per-document batch modes produce the configured request structure and stable identifiers.
22. Editing and retrying an unsent document preserves its logical IDs; sending again after confirmed success creates new IDs; and a destination-host change creates a new batch ID.
23. Automatic retry follows the specified attempt count and delays, honors `Retry-After`, waits while offline, and never automatically retries an ambiguous transmitted request when receiver idempotency is disabled.
24. Cancelling an upload preserves the draft; an interrupted upload survives sleep, quit, restart, and network loss with the documented confirmed or unconfirmed status.
25. A partial batch result identifies successful, failed, and unconfirmed documents and never resends a successful document without an explicit new-copy action.
26. Scanned payloads are encrypted at rest, plaintext staging is removed, secrets remain in Keychain, and deleting a draft makes its payload unavailable to the app.
27. Logs, notifications, recent history, profile exports, and support bundles contain none of the prohibited document content, credentials, sensitive metadata, filenames, query strings, or response bodies.
28. Redirect, TLS, reserved-header, response-size, and `open_url` restrictions pass security tests.
29. The complete workflow is operable with keyboard navigation, essential controls work with VoiceOver, and increased contrast does not hide state.
30. The signed and notarized universal app installs, updates, launches at login, and passes the compatibility matrix in section 10.2.
31. A user can enable and configure a system-wide scan shortcut that persists across launches, starts a new scan with the selected scanner's saved defaults, opens the workspace, handles unavailable/busy/unsafe states without data loss, reports shortcut conflicts, and requires no Accessibility or Input Monitoring permission.
32. A user can configure and use a separate system-wide webcam shortcut without changing or colliding silently with the scan shortcut.
33. Operational settings and safe last-used values persist so repeated scan, webcam, and upload workflows do not ask the same questions on every capture.
34. Scanner documents, webcam photos, and watched-folder imports enter an encrypted local Document Library by default; the user can search/filter, preview, reopen, export, send again with new IDs, inspect storage use, and explicitly remove a local copy without changing the remote copy or metadata-only transfer history.

## 12. Success measures

- Median time from scan completion to pressing **Send** is under 15 seconds.
- At least 95% of initiated uploads reach a confirmed result without requiring manual file handling.
- Fewer than 1% of successful uploads create a duplicate remote document when the receiver honors `document_id` idempotency.
- At least 90% of pilot users complete first-time destination setup without developer assistance when given endpoint credentials.
- Crash-free session rate is at least 99.5% during the pilot.
- At least 95% of pilot users complete a first test scan without developer assistance when the supported driver is installed.
- No completed scan page is lost in the interruption, crash, sleep/wake, and queue-limit acceptance suite.
- No prohibited sensitive value appears in automated log, notification, history, profile-export, or support-bundle tests.

## 13. Delivery phases

### Phase 0 — feasibility spike

- Verify DS-1660W ImageCaptureCore discovery, flatbed, ADF, duplex ordering, progress, cancellation, button events, USB, infrastructure Wi-Fi, and Wi-Fi Direct behavior on the required macOS versions.
- Verify direct signed/notarized distribution, third-party ICA loading, Hardened Runtime, launch at login, architecture coverage, and update signing.
- Prototype encrypted page storage, crash-safe draft manifests, bounded preview generation, and 100 MB streaming upload.
- Validate watched-folder stability detection, duplicate prevention, multi-page PDF/TIFF import, and unavailable-volume recovery.
- Build a reference receiver covering every request mode, response mapping, idempotent retry, partial success, malformed response, and size limit.

### Phase 1 — internal MVP

- First-run onboarding, menu-bar lifecycle, draft queue, notifications, and recent transfers.
- Native and watched-folder acquisition with interruption recovery.
- Preview, page operations, output generation, compression choices, encrypted storage, and crash recovery.
- Destination profiles, typed metadata forms, Keychain credentials, response mapping, upload, retry, and diagnostics.
- Automated security, accessibility, lifecycle, and network-failure tests.

### Phase 2 — pilot hardening

- Broader scanner compatibility testing.
- Accessibility and performance verification.
- Update rollout, managed configuration, centrally locked profiles, and support diagnostics.
- Additional validated scanner models and optional provider feasibility.

## 14. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Scanner button events are inconsistent across macOS drivers. | The app may not activate from the physical button. | Support in-app scan and watched-folder import as first-class paths; publish a compatibility list. |
| The name “TWAIN” implies a driver standard that may not match current macOS device APIs. | Incorrect technical expectations. | Treat TwainBridge as the product name; validate native Image Capture compatibility in Phase 0. |
| Retrying an ambiguous request may create duplicates. | Duplicate records in the target system. | Persist a stable `document_id` and require receiver-side idempotency for robust integrations. |
| Large scans consume memory or freeze preview. | Poor reliability. | Stream file assembly and upload, generate bounded preview images, and avoid loading full pages into memory simultaneously. |
| Endpoint misconfiguration could expose private documents. | Privacy or compliance incident. | HTTPS-only defaults, explicit destination testing, Keychain storage, safe redirect handling, and clear destination identity in preview. |
| Watched folders may contain unrelated or partially written files. | Incorrect imports or corrupt drafts. | Filter supported types, wait for file stability, copy into private storage, detect duplicates, and allow a dedicated folder per device. |
| The DS-1660W is discontinued and a future macOS release may break its vendor driver. | The pilot scanner may stop working after an OS update. | Pin and publish the tested matrix, detect unverified driver versions, retain watched-folder fallback, and test macOS updates before declaring support. |
| Third-party ICA behavior differs by transport and driver version. | A capability may appear but fail during acquisition. | Treat capabilities as provisional until a test scan succeeds, cache results by device and driver version, and provide actionable fallback. |
| A generic response mapping may incorrectly classify a remote result. | A document may be shown as sent when it was not accepted. | Offer Test Connection as an optional diagnostic, validate mappings, cap response size, and treat missing required paths as unconfirmed. |
| Local encryption-key loss makes retained drafts unreadable. | Unsent documents cannot be recovered after Keychain loss. | Detect the condition, never overwrite encrypted drafts, offer support diagnostics, and tell the user to recover from the original scan or watched-folder source. |
| Many queued drafts or large batches exhaust disk space. | Scanning or import fails and drafts may become unusable. | Check available space before acquisition/import, reserve working headroom, enforce queue limits, and never delete an existing draft automatically. |
| A receiver does not implement idempotency despite being configured as supported. | Ambiguous retries can create duplicates. | Make the setting explicit, test it with the reference receiver, preserve identifiers, and expose unconfirmed status and correlation IDs. |

## 15. Open product decisions

- Which scanner models, if any, must be supported in addition to the required Epson DS-1660W?
- Which concrete pilot endpoints and metadata schemas must ship as preconfigured profiles?
- Does any pilot endpoint require authentication beyond bearer token or custom header, such as OAuth 2.0 or mutual TLS?
- Should a successful upload open the web record automatically or only show an optional action?
- What local retention policy is required by the organization?
- Is central configuration through MDM required for deployment?

## 16. Future considerations

- OCR and searchable PDF generation.
- Automatic deskew, crop, blank-page removal, and compression presets.
- Server-provided dynamic metadata schemas and document-type rules.
- QR code, barcode, or separator-page routing.
- Signed destination configuration profiles for managed deployment.
- Centrally locked profiles and policy enforcement through MDM.
- OAuth 2.0, mutual TLS, and other renewable authentication methods.
- Direct TWAIN Classic, eSCL/AirScan, TWAIN Direct, SANE, or vendor-SDK providers when justified by validated hardware demand.
- PDF/A, digital signatures, and organization-specific archival formats.
- Windows companion application with an appropriate scanner API.
