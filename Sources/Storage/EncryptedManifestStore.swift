import CryptoKit
import Foundation

enum EncryptedManifestStoreError: LocalizedError {
    case invalidContainer
    case tooLarge
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidContainer: String(localized: "The encrypted draft manifest is invalid.")
        case .tooLarge: String(localized: "The draft manifest exceeds the safe size limit.")
        case .authenticationFailed: String(localized: "The encrypted draft manifest failed authentication.")
        }
    }
}

/// Small authenticated container for draft structure and metadata. Page data
/// uses the separate bounded, chunked EncryptedFileStore container.
enum EncryptedManifestStore {
    private static let magic = Data("TBM1".utf8)
    private static let maximumPlaintextBytes = 16 * 1_048_576

    static func write(_ plaintext: Data, to destination: URL, keyData: Data) throws {
        guard plaintext.count <= maximumPlaintextBytes else {
            throw EncryptedManifestStoreError.tooLarge
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: magic
        )
        guard let combined = sealed.combined else {
            throw EncryptedManifestStoreError.authenticationFailed
        }
        try (magic + combined).write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    static func read(from source: URL, keyData: Data) throws -> Data {
        let container = try Data(contentsOf: source, options: .mappedIfSafe)
        guard container.count > magic.count + 28,
              container.prefix(magic.count) == magic,
              container.count <= maximumPlaintextBytes + magic.count + 64 else {
            throw EncryptedManifestStoreError.invalidContainer
        }
        do {
            let box = try AES.GCM.SealedBox(combined: container.dropFirst(magic.count))
            let plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: keyData),
                authenticating: magic
            )
            guard plaintext.count <= maximumPlaintextBytes else {
                throw EncryptedManifestStoreError.tooLarge
            }
            return plaintext
        } catch let error as EncryptedManifestStoreError {
            throw error
        } catch {
            throw EncryptedManifestStoreError.authenticationFailed
        }
    }
}
