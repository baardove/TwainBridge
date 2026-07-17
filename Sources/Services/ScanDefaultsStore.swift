import Foundation

struct ScanProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var source: ScanSource
    var colorMode: ScanColorMode
    var resolution: Int
    var duplex: Bool
    var pageSize: ScanPageSize
    var orientation: ScanOrientation
}

@MainActor
final class ScanDefaultsStore: ObservableObject {
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let key = "scanner.lastSuccessfulSettings"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func save(_ request: ScanRequest) {
        var values = storedValues()
        values[request.scannerID] = request
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: key)
            revision += 1
        }
    }

    func request(for scannerID: String) -> ScanRequest {
        storedValues()[scannerID] ?? ScanRequest(
            scannerID: scannerID,
            source: .automatic,
            colorMode: .color,
            resolution: 300,
            duplex: true
        )
    }

    func exportProfile(_ request: ScanRequest) throws -> Data {
        let profile = ScanProfile(
            source: request.source,
            colorMode: request.colorMode,
            resolution: request.resolution,
            duplex: request.duplex,
            pageSize: request.pageSize,
            orientation: request.orientation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    func importProfile(_ data: Data, scannerID: String) throws -> ScanRequest {
        let profile = try JSONDecoder().decode(ScanProfile.self, from: data)
        guard profile.version == ScanProfile.currentVersion else {
            throw DraftStoreError.unsupportedManifestVersion(profile.version)
        }
        let request = ScanRequest(
            scannerID: scannerID,
            source: profile.source,
            colorMode: profile.colorMode,
            resolution: profile.resolution,
            duplex: profile.duplex,
            pageSize: profile.pageSize,
            orientation: profile.orientation
        )
        save(request)
        return request
    }

    private func storedValues() -> [String: ScanRequest] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: ScanRequest].self, from: data) else { return [:] }
        return decoded
    }
}
