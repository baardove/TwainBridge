import Foundation

@MainActor
final class DestinationStore: ObservableObject {
    @Published private(set) var profiles: [DestinationProfile] = []
    @Published var defaultDestinationID: UUID?
    @Published var selectedDestinationID: UUID? {
        didSet {
            guard persistenceIsActive, selectedDestinationID != oldValue else { return }
            persist()
        }
    }
    @Published private(set) var lastError: String?

    private let storageURL: URL?
    private var persistenceIsActive = false

    init(rootURL: URL? = nil) {
        do {
            let root = try rootURL ?? Self.defaultRootURL()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            storageURL = root.appendingPathComponent("destinations.json")
            load()
        } catch {
            storageURL = nil
            lastError = error.localizedDescription
        }
        persistenceIsActive = true
    }

    var defaultDestination: DestinationProfile? {
        profile(id: defaultDestinationID) ?? profiles.first
    }

    func profile(id: UUID?) -> DestinationProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func createDestination() -> DestinationProfile {
        var profile = DestinationProfile()
        profile.filenamePattern = UserDefaults.standard.string(forKey: "document.defaultFilenamePattern")
            ?? profile.filenamePattern
        profiles.append(profile)
        selectedDestinationID = profile.id
        if defaultDestinationID == nil { defaultDestinationID = profile.id }
        persist()
        return profile
    }

    func save(_ profile: DestinationProfile, credential: String? = nil) throws {
        var sanitized = profile.sanitizedForPersistence()
        if sanitized.authentication.kind == .none {
            try KeychainStore.delete(account: credentialAccount(profile.id))
        } else if let credential {
            if credential.isEmpty {
                try KeychainStore.delete(account: credentialAccount(profile.id))
            } else {
                try KeychainStore.set(Data(credential.utf8), account: credentialAccount(profile.id))
            }
        }
        sanitized.lastConnectionTestSucceeded = profile.lastConnectionTestSucceeded
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            let retainedParameterIDs = Set(profile.parameters.map(\.id))
            for parameter in profiles[index].parameters where !retainedParameterIDs.contains(parameter.id) {
                try? KeychainStore.delete(account: parameterAccount(profile.id, parameter.id))
                try? KeychainStore.delete(account: rememberedParameterAccount(profile.id, parameter.id))
            }
            profiles[index] = sanitized
        } else {
            profiles.append(sanitized)
        }
        for parameter in profile.parameters where !parameter.rememberValue {
            try? KeychainStore.delete(account: rememberedParameterAccount(profile.id, parameter.id))
        }
        if defaultDestinationID == nil { defaultDestinationID = sanitized.id }
        try persistThrowing()
    }

    func delete(_ id: UUID) throws {
        if let existing = profile(id: id) {
            for parameter in existing.parameters {
                try? KeychainStore.delete(account: parameterAccount(id, parameter.id))
                try? KeychainStore.delete(account: rememberedParameterAccount(id, parameter.id))
            }
        }
        profiles.removeAll { $0.id == id }
        try KeychainStore.delete(account: credentialAccount(id))
        if defaultDestinationID == id { defaultDestinationID = profiles.first?.id }
        if selectedDestinationID == id { selectedDestinationID = profiles.first?.id }
        try persistThrowing()
    }

    func setDefault(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        defaultDestinationID = id
        persist()
    }

    func credential(for destinationID: UUID) -> String? {
        guard let data = try? KeychainStore.data(account: credentialAccount(destinationID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasCredential(for destinationID: UUID) -> Bool {
        credential(for: destinationID)?.isEmpty == false
    }

    func validationIssues(for profile: DestinationProfile) -> [DestinationValidationIssue] {
        var issues = DestinationValidator.validate(profile, hasAuthenticationSecret: hasCredential(for: profile.id))
        for parameter in profile.parameters
        where parameter.enabled && parameter.required && parameter.sensitive && parameter.valueSource == .fixed {
            if parameterSecret(profileID: profile.id, parameterID: parameter.id)?.isEmpty != false {
                issues.append(.init(
                    id: "parameter.\(parameter.id).secret",
                    severity: .error,
                    message: String(localized: "Enter a Keychain value for required parameter ‘\(parameter.name)’.")
                ))
            }
        }
        return issues
    }

    func parameterSecret(profileID: UUID, parameterID: UUID) -> String? {
        guard let data = try? KeychainStore.data(account: parameterAccount(profileID, parameterID)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setParameterSecret(_ value: String, profileID: UUID, parameterID: UUID) throws {
        if value.isEmpty {
            try KeychainStore.delete(account: parameterAccount(profileID, parameterID))
        } else {
            try KeychainStore.set(Data(value.utf8), account: parameterAccount(profileID, parameterID))
        }
    }

    func rememberedParameterValue(profileID: UUID, parameterID: UUID) -> String? {
        guard let data = try? KeychainStore.data(account: rememberedParameterAccount(profileID, parameterID)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setRememberedParameterValue(_ value: String, profileID: UUID, parameterID: UUID) throws {
        if value.isEmpty {
            try KeychainStore.delete(account: rememberedParameterAccount(profileID, parameterID))
        } else {
            try KeychainStore.set(Data(value.utf8), account: rememberedParameterAccount(profileID, parameterID))
        }
    }

    func exportProfile(_ id: UUID) throws -> Data {
        guard let profile = profile(id: id) else { throw DraftStoreError.draftNotFound }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(profile.exportedCopy())
    }

    @discardableResult
    func importProfile(_ data: Data) throws -> DestinationProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var imported = try decoder.decode(DestinationProfile.self, from: data)
        guard imported.version == DestinationProfile.profileVersion else {
            throw DraftStoreError.unsupportedManifestVersion(imported.version)
        }
        imported.id = UUID()
        imported = imported.exportedCopy()
        imported.enabled = imported.authentication.kind == .none
            && !imported.parameters.contains(where: { $0.sensitive })
        let issues = DestinationValidator.validate(imported, hasAuthenticationSecret: false)
        guard !issues.contains(where: { $0.severity == .error && $0.id != "auth.secret" }) else {
            throw DestinationStoreError.invalidProfile(issues.map(\.message).joined(separator: " "))
        }
        profiles.append(imported)
        if defaultDestinationID == nil { defaultDestinationID = imported.id }
        try persistThrowing()
        return imported
    }

    func recordConnectionTest(profileID: UUID, result: ConnectionTestResult) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw DestinationStoreError.profileNotFound
        }
        profiles[index].lastConnectionTestAt = Date()
        profiles[index].lastConnectionTestSucceeded = result.succeeded
        try persistThrowing()
    }

    private func load() {
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let collection = try decoder.decode(DestinationCollection.self, from: Data(contentsOf: storageURL))
            guard collection.version == 1 else {
                throw DestinationStoreError.invalidProfile(String(localized: "Unsupported destination collection version."))
            }
            profiles = collection.profiles.map { $0.sanitizedForPersistence() }
            defaultDestinationID = collection.defaultDestinationID
            let candidate = collection.lastSelectedDestinationID ?? defaultDestinationID
            selectedDestinationID = profiles.contains(where: { $0.id == candidate })
                ? candidate
                : defaultDestinationID ?? profiles.first?.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist() {
        do { try persistThrowing(); lastError = nil } catch { lastError = error.localizedDescription }
    }

    private func persistThrowing() throws {
        guard let storageURL else { throw DestinationStoreError.storageUnavailable }
        let collection = DestinationCollection(
            defaultDestinationID: defaultDestinationID,
            lastSelectedDestinationID: selectedDestinationID,
            profiles: profiles.map { $0.sanitizedForPersistence() }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(collection).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private func credentialAccount(_ id: UUID) -> String { "destination.\(id.uuidString).credential" }
    private func parameterAccount(_ profileID: UUID, _ parameterID: UUID) -> String {
        "destination.\(profileID.uuidString).parameter.\(parameterID.uuidString)"
    }
    private func rememberedParameterAccount(_ profileID: UUID, _ parameterID: UUID) -> String {
        "destination.\(profileID.uuidString).remembered.\(parameterID.uuidString)"
    }

    private static func defaultRootURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("TwainBridge", isDirectory: true)
    }
}

enum DestinationStoreError: LocalizedError {
    case storageUnavailable
    case profileNotFound
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: String(localized: "Destination storage is unavailable.")
        case .profileNotFound: String(localized: "The destination profile could not be found.")
        case let .invalidProfile(message): String(localized: "The destination profile is invalid: \(message)")
        }
    }
}
