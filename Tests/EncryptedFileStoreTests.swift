import CryptoKit
import XCTest
@testable import TwainBridge

final class EncryptedFileStoreTests: XCTestCase {
    func testChunkedEncryptionRoundTripsMoreThanTwoChunks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        let encrypted = directory.appendingPathComponent("encrypted.tbpage")
        let decrypted = directory.appendingPathComponent("decrypted.bin")
        let original = Data((0..<(2_500_000)).map { UInt8($0 % 251) })
        try original.write(to: source)

        try EncryptedFileStore.encrypt(source: source, destination: encrypted, keyData: Data(repeating: 7, count: 32))
        try EncryptedFileStore.decrypt(source: encrypted, destination: decrypted, keyData: Data(repeating: 7, count: 32))

        XCTAssertEqual(try Data(contentsOf: decrypted), original)
        XCTAssertNotEqual(try Data(contentsOf: encrypted), original)
        let encryptedPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: encrypted.path)[.posixPermissions] as? NSNumber
        )
        let decryptedPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: decrypted.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(encryptedPermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(decryptedPermissions.intValue & 0o777, 0o600)
    }

    func testTamperedCiphertextIsRejectedAndPartialOutputRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        let encrypted = directory.appendingPathComponent("encrypted.tbpage")
        let output = directory.appendingPathComponent("output.bin")
        try Data(repeating: 42, count: 50_000).write(to: source)
        try EncryptedFileStore.encrypt(source: source, destination: encrypted, keyData: Data(repeating: 3, count: 32))

        var payload = try Data(contentsOf: encrypted)
        payload[40] ^= 0xff
        try payload.write(to: encrypted)

        XCTAssertThrowsError(
            try EncryptedFileStore.decrypt(
                source: encrypted,
                destination: output,
                keyData: Data(repeating: 3, count: 32)
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
