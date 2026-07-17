import Foundation

@MainActor
final class TransferHistoryStore: ObservableObject {
    @Published private(set) var entries: [TransferHistoryEntry] = []
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "history.enabled")
            if !isEnabled { clear() }
        }
    }

    private let storageURL: URL?

    init(rootURL: URL? = nil) {
        isEnabled = UserDefaults.standard.object(forKey: "history.enabled") as? Bool ?? true
        let root = rootURL ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TwainBridge", isDirectory: true))
        storageURL = root?.appendingPathComponent("transfer-history.json")
        load()
    }

    func record(_ entry: TransferHistoryEntry) {
        guard isEnabled else { return }
        entries.insert(entry, at: 0)
        prune()
        persist()
    }

    func clear() {
        entries = []
        if let storageURL { try? FileManager.default.removeItem(at: storageURL) }
    }

    private func load() {
        guard isEnabled, let storageURL, let data = try? Data(contentsOf: storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([TransferHistoryEntry].self, from: data)) ?? []
        prune()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        entries = Array(entries.filter { $0.timestamp >= cutoff }.prefix(50))
    }

    private func persist() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: storageURL.deletingLastPathComponent().path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch { }
    }
}
