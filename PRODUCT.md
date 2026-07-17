# Product

## Register

product

## Users

TwainBridge primarily serves office workers who repeatedly move invoices, contracts, identity documents, forms, and case material into browser-based business systems. They work in short, interruption-prone capture sessions and need the scanner or camera to feel like a direct extension of the destination web application rather than a separate file-management task.

A secondary user is the IT administrator or web-application owner who configures capture devices, upload destinations, authentication, posting parameters, retention, and operational defaults. This user needs precise diagnostics and policy controls without exposing that complexity during routine scanning.

## Product Purpose

TwainBridge closes the gap between local macOS capture hardware and web applications that cannot access scanners or cameras directly. It receives pages from ImageCaptureCore scanners, AVFoundation cameras, or watched folders; encrypts and retains them locally; presents a focused review; and sends the resulting PDF or JPEG to a configured HTTP endpoint only when the user chooses Send.

Success means the normal workflow is a hotkey or hardware action, one visual check, and one Send action. Configuration persists, repeated choices are remembered, advanced controls remain available without interrupting the common path, and failures preserve completed work with a clear recovery action.

## Brand Personality

Quiet, trustworthy, and efficient. TwainBridge should feel like a well-made native macOS utility: calm in the background, immediate when a document arrives, precise about state, and candid about errors. Its voice is concise and operational. It reassures through visible control, predictable behavior, and respect for the user's documents rather than through decorative warmth or promotional language.

## Anti-references

- A full document-management suite that turns a send task into filing, classification, or workflow administration.
- A scanner-vendor control center crowded with every hardware capability on the primary screen.
- A generic cloud uploader that obscures where documents are stored or when transmission occurs.
- A professional image editor with dense tools, floating palettes, and editing features beyond document preparation.
- A question-heavy wizard that asks for the same destination, format, source, or posting values on every capture.
- A custom-styled cross-platform shell that replaces familiar macOS controls, keyboard behavior, and system status conventions for visual novelty.
- An unattended automation agent that uploads sensitive documents without an explicit user Send action.

## Design Principles

1. **One check, one send.** After capture, show the document, its essential status, Advanced, and Send. Do not make routine users traverse configuration or document-management UI.
2. **Progressive depth.** Keep scanner capabilities, batch structure, page tools, output controls, metadata, diagnostics, and recovery available in Advanced without placing them on the primary path.
3. **Remember safe choices.** Persist last-used scanner, source, camera, destination, output, preview, hotkeys, and reusable parameters. Repeat proven actions instead of asking repeated questions.
4. **Make trust observable.** State what is local, what is encrypted, what will be sent, whether the receiver confirmed it, and what remains recoverable. Never imply success from an ambiguous response.
5. **Preserve work before optimizing flow.** Completed pages, interrupted drafts, and uncertain uploads survive failures. Recovery must be explicit, idempotency-aware, and free of silent data loss or duplication.
6. **Use the Mac as users expect.** Prefer native controls, system permissions, Keychain, system trust, keyboard shortcuts, semantic colors, and standard accessibility behavior.

## Accessibility & Inclusion

The complete workflow must support keyboard navigation, essential controls must expose meaningful accessibility labels and work with VoiceOver, and Increased Contrast must not hide state. Status must be communicated with text and symbols, never color alone. Focus order and default actions must follow macOS conventions.

Global scanner and webcam shortcuts must work without Accessibility or Input Monitoring permission. Motion is limited to state feedback and must respect reduced-motion preferences on web surfaces. All user-facing strings are externalized for future localization, and privacy-sensitive notifications avoid filenames and metadata.
