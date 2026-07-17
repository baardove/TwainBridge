# Signed update feed

TwainBridge accepts a small HTTPS JSON manifest. The Ed25519 signature covers the canonical, sorted-key JSON encoding of `version`, `build`, `minimum_macos`, `download_url`, and `sha256`. The package is not exposed to the user until its streamed SHA-256 matches the signed value.

Example unsigned fields:

```json
{
  "build": 2,
  "download_url": "https://updates.example.com/twainbridge/TwainBridge-1.0.1-universal.zip",
  "minimum_macos": "15.0",
  "sha256": "64 lowercase hexadecimal characters",
  "version": "1.0.1"
}
```

Generate an Ed25519 private key once and keep it outside the repository. A suitable raw key file can be created with a short CryptoKit utility; it must contain only the base64-encoded 32-byte private key and have restrictive filesystem permissions. Never put it in an xcconfig or CI log.

Create the release manifest:

```sh
swift Scripts/sign-update-manifest.swift \
  1.0.1 2 15.0 \
  build/Release/TwainBridge-1.0.1-universal.zip \
  https://updates.example.com/twainbridge/TwainBridge-1.0.1-universal.zip \
  /secure/path/twainbridge-update-private-key.base64 \
  build/Release/manifest.json
```

Put the printed public key and HTTPS manifest URL in the private `Config/Release.xcconfig`. Upload the package and manifest atomically, with the package first. The app follows only same-host manifest redirects, never bypasses TLS, and does not automatically install updates.
