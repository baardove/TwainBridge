#!/usr/bin/env swift

import CryptoKit
import Foundation

struct Payload: Codable {
    var version: String
    var build: Int
    var minimumMacOS: String
    var downloadURL: String
    var sha256: String

    enum CodingKeys: String, CodingKey {
        case version, build, sha256
        case minimumMacOS = "minimum_macos"
        case downloadURL = "download_url"
    }
}

struct Manifest: Codable {
    var version: String
    var build: Int
    var minimumMacOS: String
    var downloadURL: String
    var sha256: String
    var signature: String

    enum CodingKeys: String, CodingKey {
        case version, build, sha256, signature
        case minimumMacOS = "minimum_macos"
        case downloadURL = "download_url"
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 8 else {
    fail("usage: sign-update-manifest.swift VERSION BUILD MINIMUM_MACOS PACKAGE DOWNLOAD_URL PRIVATE_KEY_FILE OUTPUT_JSON")
}

let version = CommandLine.arguments[1]
guard let build = Int(CommandLine.arguments[2]), build > 0 else { fail("BUILD must be a positive integer") }
let minimumMacOS = CommandLine.arguments[3]
let packageURL = URL(fileURLWithPath: CommandLine.arguments[4]).standardizedFileURL
guard FileManager.default.isReadableFile(atPath: packageURL.path) else { fail("PACKAGE is not readable") }
guard let downloadURL = URL(string: CommandLine.arguments[5]), downloadURL.scheme?.lowercased() == "https" else {
    fail("DOWNLOAD_URL must be HTTPS")
}
let privateKeyURL = URL(fileURLWithPath: CommandLine.arguments[6]).standardizedFileURL
let outputURL = URL(fileURLWithPath: CommandLine.arguments[7]).standardizedFileURL

let encodedKey = (try? String(contentsOf: privateKeyURL, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let encodedKey, let keyData = Data(base64Encoded: encodedKey),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    fail("PRIVATE_KEY_FILE must contain a base64-encoded raw Ed25519 private key")
}

let handle = try FileHandle(forReadingFrom: packageURL)
defer { try? handle.close() }
var hasher = SHA256()
while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

let payload = Payload(
    version: version,
    build: build,
    minimumMacOS: minimumMacOS,
    downloadURL: downloadURL.absoluteString,
    sha256: hash
)
let canonicalEncoder = JSONEncoder()
canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let signature = try privateKey.signature(for: canonicalEncoder.encode(payload)).base64EncodedString()
let manifest = Manifest(
    version: version,
    build: build,
    minimumMacOS: minimumMacOS,
    downloadURL: downloadURL.absoluteString,
    sha256: hash,
    signature: signature
)
let outputEncoder = JSONEncoder()
outputEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try outputEncoder.encode(manifest).write(to: outputURL, options: .atomic)

print("Manifest: \(outputURL.path)")
print("Public key: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
