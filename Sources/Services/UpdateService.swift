import AppKit
import CryptoKit
import Foundation

struct UpdateManifest: Codable, Equatable, Sendable {
    var version: String
    var build: Int
    var minimumMacOS: String
    var downloadURL: String
    var sha256: String
    var signature: String

    private enum CodingKeys: String, CodingKey {
        case version, build, signature
        case minimumMacOS = "minimum_macos"
        case downloadURL = "download_url"
        case sha256
    }

    var signedPayload: UpdateSignedPayload {
        .init(
            version: version,
            build: build,
            minimumMacOS: minimumMacOS,
            downloadURL: downloadURL,
            sha256: sha256
        )
    }
}

struct UpdateSignedPayload: Codable, Equatable, Sendable {
    var version: String
    var build: Int
    var minimumMacOS: String
    var downloadURL: String
    var sha256: String

    private enum CodingKeys: String, CodingKey {
        case version, build
        case minimumMacOS = "minimum_macos"
        case downloadURL = "download_url"
        case sha256
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

@MainActor
final class UpdateService: ObservableObject {
    enum Status: Equatable {
        case idle
        case notConfigured
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case ready(String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: String(localized: "Not checked")
            case .notConfigured: String(localized: "Update feed is not configured in this build")
            case .checking: String(localized: "Checking…")
            case .upToDate: String(localized: "TwainBridge is up to date")
            case let .available(version): String(localized: "Version \(version) is available")
            case let .downloading(progress): String(localized: "Downloading… \(Int(progress * 100))%")
            case let .ready(version): String(localized: "Version \(version) is verified and ready")
            case let .failed(message): message
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading: true
            default: false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var availableManifest: UpdateManifest?
    @Published private(set) var verifiedPackageURL: URL?
    @Published var automaticChecksEnabled: Bool {
        didSet { UserDefaults.standard.set(automaticChecksEnabled, forKey: "updates.automaticChecks") }
    }

    private let feedURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?

    init(bundle: Bundle = .main) {
        automaticChecksEnabled = UserDefaults.standard.object(forKey: "updates.automaticChecks") as? Bool ?? true
        let feed = bundle.object(forInfoDictionaryKey: "TwainBridgeUpdateFeedURL") as? String
        let key = bundle.object(forInfoDictionaryKey: "TwainBridgeUpdatePublicKey") as? String
        if let feed, let url = URL(string: feed), url.scheme?.lowercased() == "https", !feed.isEmpty {
            feedURL = url
        } else {
            feedURL = nil
        }
        if let key, let data = Data(base64Encoded: key), let parsed = try? Curve25519.Signing.PublicKey(rawRepresentation: data) {
            publicKey = parsed
        } else {
            publicKey = nil
        }
        if feedURL == nil || publicKey == nil { status = .notConfigured }
    }

    var isConfigured: Bool { feedURL != nil && publicKey != nil }

    func checkForUpdates() async {
        guard !status.isBusy else { return }
        guard let feedURL, let publicKey else {
            status = .notConfigured
            return
        }
        status = .checking
        availableManifest = nil
        verifiedPackageURL = nil

        do {
            let delegate = BoundedUploadDelegate(
                originalHost: feedURL.host?.lowercased() ?? "",
                allowedHosts: [],
                sensitiveHeaderNames: [],
                maximumResponseBytes: 65_536,
                progress: { _ in }
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await delegate.data(using: session, request: URLRequest(url: feedURL))
            guard (200...299).contains(response.statusCode) else {
                throw UpdateError.httpStatus(response.statusCode)
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            try UpdateVerifier.verify(manifest, publicKey: publicKey)
            guard supportsCurrentMac(manifest.minimumMacOS) else { throw UpdateError.unsupportedMacOS }
            if isNewer(manifest) {
                availableManifest = manifest
                status = .available(manifest.version)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func downloadAndVerifyAvailableUpdate() async {
        guard !status.isBusy, let manifest = availableManifest else { return }
        guard let url = URL(string: manifest.downloadURL), url.scheme?.lowercased() == "https" else {
            status = .failed(UpdateError.invalidDownloadURL.localizedDescription)
            return
        }
        status = .downloading(0)
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw UpdateError.invalidDownloadResponse
            }
            guard response.url?.scheme?.lowercased() == "https" else { throw UpdateError.invalidDownloadURL }
            let digest = try sha256(of: temporaryURL)
            guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
                throw UpdateError.packageHashMismatch
            }

            let updates = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("TwainBridge/VerifiedUpdates", isDirectory: true)
            try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updates.path)
            let safeExtension = ["dmg", "zip", "pkg"].contains(url.pathExtension.lowercased())
                ? url.pathExtension.lowercased()
                : "dmg"
            let destination = updates.appendingPathComponent("TwainBridge-\(manifest.version).\(safeExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            verifiedPackageURL = destination
            status = .ready(manifest.version)
        } catch {
            verifiedPackageURL = nil
            status = .failed(error.localizedDescription)
        }
    }

    func openVerifiedUpdate() {
        guard let verifiedPackageURL else { return }
        NSWorkspace.shared.open(verifiedPackageURL)
    }

    private func isNewer(_ manifest: UpdateManifest) -> Bool {
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        if manifest.build != currentBuild { return manifest.build > currentBuild }
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return manifest.version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    private func supportsCurrentMac(_ minimum: String) -> Bool {
        let components = minimum.split(separator: ".").compactMap { Int($0) }
        guard !components.isEmpty else { return false }
        let required = OperatingSystemVersion(
            majorVersion: components[0],
            minorVersion: components.count > 1 ? components[1] : 0,
            patchVersion: components.count > 2 ? components[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum UpdateVerifier {
    static func verify(_ manifest: UpdateManifest, publicKey: Curve25519.Signing.PublicKey) throws {
        guard manifest.build > 0,
              !manifest.version.isEmpty,
              manifest.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              let downloadURL = URL(string: manifest.downloadURL),
              downloadURL.scheme?.lowercased() == "https",
              let signature = Data(base64Encoded: manifest.signature),
              publicKey.isValidSignature(signature, for: try manifest.signedPayload.canonicalData()) else {
            throw UpdateError.invalidSignature
        }
    }
}

enum UpdateError: LocalizedError {
    case httpStatus(Int)
    case invalidSignature
    case invalidDownloadURL
    case invalidDownloadResponse
    case packageHashMismatch
    case unsupportedMacOS

    var errorDescription: String? {
        switch self {
        case let .httpStatus(status): String(localized: "The update feed returned HTTP \(status).")
        case .invalidSignature: String(localized: "The update manifest signature is invalid. No update was trusted.")
        case .invalidDownloadURL: String(localized: "The signed update did not contain a valid HTTPS download URL.")
        case .invalidDownloadResponse: String(localized: "The update package could not be downloaded securely.")
        case .packageHashMismatch: String(localized: "The downloaded update failed signature-linked hash verification and was discarded.")
        case .unsupportedMacOS: String(localized: "This update requires a newer version of macOS.")
        }
    }
}
