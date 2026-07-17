import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData: String(localized: "Keychain returned data in an unexpected format.")
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "Keychain error \(status).")
        }
    }
}

enum KeychainStore {
    static let service = "com.45webs.TwainBridge"

    static func data(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = item as? Data else { throw KeychainStoreError.unexpectedData }
        return data
    }

    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            attributes.forEach { newItem[$0.key] = $0.value }
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.status(updateStatus)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }
}

enum InstallationKeyProvider {
    private static let account = "draft-encryption-key-v1"

    static func loadOrCreate(encryptedDraftRootURL: URL? = nil) throws -> Data {
        if let existing = try KeychainStore.data(account: account) {
            guard existing.count == 32 else { throw KeychainStoreError.unexpectedData }
            return existing
        }

        if let encryptedDraftRootURL, containsEncryptedDraftData(at: encryptedDraftRootURL) {
            throw InstallationKeyError.missingForExistingDrafts
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        let data = Data(bytes)
        try KeychainStore.set(data, account: account)
        return data
    }

    static func containsEncryptedDraftData(at rootURL: URL) -> Bool {
        let fileManager = FileManager.default
        for relativeDirectory in ["Drafts", "Payloads"] {
            let directory = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator {
                if file.pathExtension == "tbmanifest" || file.pathExtension == "tbpage" {
                    return true
                }
            }
        }
        return false
    }
}

enum InstallationKeyError: LocalizedError {
    case missingForExistingDrafts

    var errorDescription: String? {
        switch self {
        case .missingForExistingDrafts:
            String(localized: "The draft encryption key is missing, but encrypted drafts still exist. TwainBridge will not replace the key or overwrite those drafts. Restore the original Keychain item, or recover the documents from their original scan source before clearing local drafts.")
        }
    }
}
