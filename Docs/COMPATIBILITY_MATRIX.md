# TwainBridge compatibility matrix

This matrix is a release gate, not a claim of compatibility. “Pending” means the code path exists but has not been validated with the named physical hardware, OS, architecture, or external service.

| Area | Required case | Status | Evidence / notes |
|---|---|---:|---|
| Scanner | Epson WorkForce DS-1660W, USB | Pending physical test | Native ImageCaptureCore provider implemented. |
| Scanner | Epson WorkForce DS-1660W, infrastructure Wi-Fi | Pending physical test | ICA network discovery implemented; local-network purpose string present. |
| Scanner | Epson WorkForce DS-1660W, Wi-Fi Direct | Pending physical test | Must record whether ICA discovery and scanning work in the direct-device network mode. |
| Driver | Epson ICA / Epson Scan 2 6.7.84.0 | Detected locally, unverified with hardware | `/Library/Image Capture/Devices/EPSON ES022D.app` 6.7.84.0 was detected during development. Detection is not a scan test. |
| Source | Flatbed | Pending physical test | ICA flatbed selection and supported page sizes implemented. |
| Source | ADF simplex / duplex | Pending physical test | Feeder selection, loaded state, and duplex capability implemented. |
| ADF | Empty feeder | Pending physical test | Must preserve any completed pages and present actionable feeder-empty recovery. |
| ADF | Jam after completed pages | Pending physical test | Must preserve only fully decoded pages and offer Keep, Continue, and Discard. |
| ADF | Cancellation | Pending physical test | Must cancel safely, preserve completed pages, and exclude a partial page. |
| ADF | 50-page job | Pending physical test | Must preserve order, duplex pairing, progress, responsiveness, and bounded memory. |
| Control | 150/200/300/600 dpi, color/gray/B&W | Pending physical test | Values are constrained to ICA-reported resolutions. |
| Control | A4, A5, Letter, Legal, business card | Pending physical test | Only ICA-reported document types are offered. |
| Button | Physical scanner button | Pending physical test | `ICDeviceBrowserDelegate.requestsSelect` path implemented; watched folder remains fallback. |
| Control | Configurable global scan shortcut | Model/persistence tests pass; unlocked runtime pending | Carbon registration requires no Accessibility permission; verify enable, conflict reporting, persistence, invocation, and disable on an unlocked Mac. |
| Camera | Built-in FaceTime/webcam | Pending physical UI test | Verify permission prompt, live preview, capture, encrypted draft import, denial recovery, and reconnect behavior. |
| Camera | USB webcam | Pending physical UI test | Verify selection persistence, unplug/replug handling, JPEG capture, and document preview. |
| Camera | Continuity Camera | Pending physical UI test | Verify discovery, selection, permission behavior, capture, and fallback when the iPhone disconnects. |
| Control | Configurable global webcam shortcut | Model/persistence tests pass; unlocked runtime pending | Verify independent registration, scanner-shortcut collision feedback, persistence, invocation, and disable. |
| Lifecycle | Launch at login | Pending signed clean-install test | Uses `SMAppService`; must be verified after user-controlled enablement. |
| Lifecycle | Preview closed during acquisition | Pending unlocked UI test | Completed work must reopen/present the actionable draft without loss. |
| Lifecycle | Sleep/wake | Pending system test | Draft and upload recovery paths are implemented; hardware/network behavior must be observed. |
| Lifecycle | Quit/relaunch during draft/upload | Pending system test | Encrypted draft state and confirmed per-document results must restore accurately. |
| Lifecycle | Crash after completed scan pages | Automated recovery passes; physical test pending | Recovery rejects corrupt partial files and restores valid decoded pages. |
| macOS | macOS 15, arm64 | Builds with a 15.0 deployment target; runtime pending | Physical scanner and clean-machine macOS 15 install still pending. |
| macOS | macOS 15, x86_64 | Universal compile passes; runtime pending | Release products contain arm64 and x86_64 slices; Intel runtime still needs a machine/VM. |
| macOS | macOS 26.6, arm64 | 81 automated tests pass | App logic ran on the development Mac; physical scanner/camera and clean-install matrix remain. |
| macOS | macOS 26, x86_64 | Universal compile passes; runtime pending | Intel runtime still needs a machine/VM. |
| Network | Offline before send | Implemented; matrix test pending | Draft waits without consuming retry attempts. |
| Network | Loss during upload | Implemented; matrix test pending | Idempotent receiver waits/retries; non-idempotent result becomes ambiguous. |
| Network | System proxy | Pending external test | Must confirm system proxy routing without logging URLs, queries, credentials, or response bodies. |
| HTTP | TLS failure, 408/425/429/5xx, Retry-After | Automated policy tests and receiver smoke test pass | Retry status/network classification, delta/date Retry-After parsing, and manual pause above five minutes are unit tested; trusted-TLS matrix run remains. |
| Destination | Single/multi-document, single/per-document request | Implemented; receiver smoke test passes | Reference receiver verified stable IDs, payload hashes, success, and planned 503/503/200 idempotent retry. Missing per-document results stay unconfirmed and completed documents are retained independently; full UI matrix remains. |
| Destination | Partial success | Automated interpretation passes; receiver/UI test pending | Confirmed documents must remain excluded from retry and unconfirmed documents must remain actionable. |
| Destination | Malformed response | Automated interpretation passes; receiver/UI test pending | Draft must remain safe and the result must be unconfirmed with a sanitized recovery message. |
| Destination | Generated output exceeds configured size | Automated classifier passes; UI test pending | Send must remain blocked and offer Size Options, lower-resolution rescan, Save Copy, and cancel. |
| Watched folder | Local folder and source preservation | Automated import passes; UI test pending | Security-scoped bookmark flow and nonrecursive import are implemented. |
| Watched folder | Unavailable volume / lost access | Pending system test | Intake must pause with a sanitized permission/unavailable message and bookmark recovery. |
| Watched folder | Partial or unstable file | Automated stability logic passes; system test pending | Import must wait for stable size/date samples and never delete or rename the source. |
| Watched folder | Duplicate and explicit reimport | Automated fingerprint logic passes; UI test pending | Accidental duplicate import is blocked while explicit reimport remains available. |
| Watched folder | Symbolic link to an external file | Automated tests pass | Automatic and explicit import reject symlinks so nonrecursive folder scope cannot be bypassed. |
| Watched folder | Corrupt input | Automated fixtures pass; UI test pending | Corrupt JPEG, TIFF, and PDF input is rejected without modifying the source or creating a draft. |
| Watched folder | Multipage PDF | Automated tests pass | Every page imports and reassembles with the document boundary preserved. |
| Watched folder | Multipage TIFF | Automated tests pass | Every frame imports and reassembles without modifying the source. |
| Library | Scanner/webcam/folder browsing and recall | Storage tests pass; unlocked UI test pending | Verify source filters, search, encrypted thumbnails, workspace recall, sent export, Send Again, storage total, and confirmed local removal with a representative mixed-source library. |
| Scale | 100-page PDF and 100 MiB multipart body | Automated tests pass | Page assembly preserves all 100 pages; multipart construction copies the 100 MiB file in bounded chunks. Preflight enforces process RSS below 150 MiB after three seconds and a five-second stability run; unlocked AppKit visual-ready timing remains pending. |
| Security | Redirect/header stripping, response cap, open URL policy | Automated boundary tests pass | HTTPS downgrade rejection, cross-host secret stripping, response cap, content type, support-bundle redaction, and update tampering are covered; external proxy testing remains. |
| Distribution | Developer ID, Hardened Runtime, notarization, stapling | Pending credentials | `Scripts/release.sh` prepares and validates the release. |
| Updates | Signed HTTPS manifest and verified package hash | Implemented; production feed pending | Feed URL/public key intentionally unset in development builds. |

Before release, record scanner serial-independent model name, exact driver version, macOS build, Mac architecture, connection type, source, duplex/button behavior, observed limitations, tester, and date for every completed row. Do not place scanner serial numbers, IP addresses, credentials, filenames, or document content in this file.
