import CryptoKit
import Foundation

struct WatchedFileCandidate: Sendable {
    var url: URL
    var fingerprint: String
}

actor WatchedFolderTracker {
    private struct Observation {
        var size: Int64
        var modificationDate: Date
        var firstUnchangedAt: Date
    }

    private let storageURL: URL
    private var observations: [String: Observation] = [:]
    private var importedFingerprints: Set<String> = []

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let values = try? JSONDecoder().decode(Set<String>.self, from: data) {
            importedFingerprints = values
        }
    }

    func stableCandidates(in folder: URL, now: Date = Date()) throws -> [WatchedFileCandidate] {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw WatchedFolderError.folderUnavailable
        }
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            throw WatchedFolderError.permissionLost
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        let listedFiles: [URL]
        do {
            listedFiles = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw FileManager.default.fileExists(atPath: folder.path)
                ? WatchedFolderError.permissionLost
                : WatchedFolderError.folderUnavailable
        }
        let files = listedFiles.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }

        var stable: [WatchedFileCandidate] = []
        var existingPaths: Set<String> = []
        for file in files {
            let name = file.lastPathComponent
            let ext = file.pathExtension.lowercased()
            guard WatchedFilePageExtractor.supportedExtensions.contains(ext),
                  !name.hasPrefix("."), !name.hasPrefix("~"),
                  !name.hasSuffix(".tmp"), !name.hasSuffix(".part"), !name.hasSuffix(".download") else { continue }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.isPackage != true, values.isHidden != true,
                  let sizeValue = values.fileSize,
                  let modificationDate = values.contentModificationDate,
                  FileManager.default.isReadableFile(atPath: file.path) else { continue }
            let size = Int64(sizeValue)
            let path = file.standardizedFileURL.path
            existingPaths.insert(path)
            if let previous = observations[path],
               previous.size == size, previous.modificationDate == modificationDate {
                if now.timeIntervalSince(previous.firstUnchangedAt) >= 3 {
                    guard let fingerprint = try? fingerprint(
                        file: file,
                        size: size,
                        modificationDate: modificationDate,
                        identity: values.fileResourceIdentifier.map { String(describing: $0) } ?? path
                    ) else { continue }
                    if !importedFingerprints.contains(fingerprint) {
                        stable.append(.init(url: file, fingerprint: fingerprint))
                    }
                }
            } else {
                observations[path] = .init(size: size, modificationDate: modificationDate, firstUnchangedAt: now)
            }
        }
        observations = observations.filter { existingPaths.contains($0.key) }
        return stable
    }

    func markImported(_ candidate: WatchedFileCandidate) throws {
        importedFingerprints.insert(candidate.fingerprint)
        let data = try JSONEncoder().encode(importedFingerprints)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageURL.deletingLastPathComponent().path
        )
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    func explicitCandidate(for file: URL) throws -> WatchedFileCandidate {
        let extensionName = file.pathExtension.lowercased()
        guard WatchedFilePageExtractor.supportedExtensions.contains(extensionName) else {
            throw WatchedFolderError.unsupportedFile
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey
        ]
        let values = try file.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw WatchedFolderError.symbolicLink }
        guard values.isRegularFile == true,
              let sizeValue = values.fileSize,
              let modificationDate = values.contentModificationDate,
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw WatchedFolderError.permissionLost
        }
        return try WatchedFileCandidate(
            url: file,
            fingerprint: fingerprint(
                file: file,
                size: Int64(sizeValue),
                modificationDate: modificationDate,
                identity: values.fileResourceIdentifier.map { String(describing: $0) }
                    ?? file.standardizedFileURL.path
            )
        )
    }

    private func fingerprint(file: URL, size: Int64, modificationDate: Date, identity: String) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let contentHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identityHash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(identityHash):\(size):\(modificationDate.timeIntervalSince1970):\(contentHash)"
    }
}

@MainActor
final class WatchedFolderService: ObservableObject {
    enum Status: Equatable {
        case disabled
        case watching
        case importing
        case paused(String)

        var label: String {
            switch self {
            case .disabled: String(localized: "Disabled")
            case .watching: String(localized: "Watching")
            case .importing: String(localized: "Importing…")
            case let .paused(message): message
            }
        }
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var status: Status = .disabled
    @Published private(set) var lastImportError: String?
    @Published private(set) var importedCount = 0
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? startMonitoring() : stopMonitoring()
        }
    }

    private static let bookmarkKey = "watchedFolder.bookmark"
    private static let enabledKey = "watchedFolder.enabled"
    private let draftStore: DraftStore
    private let tracker: WatchedFolderTracker
    private var monitorTask: Task<Void, Never>?
    private var accessingSecurityScope = false

    init(draftStore: DraftStore, rootURL: URL? = nil) {
        self.draftStore = draftStore
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let root = rootURL ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TwainBridge", isDirectory: true)) ?? FileManager.default.temporaryDirectory
        tracker = WatchedFolderTracker(storageURL: root.appendingPathComponent("watched-fingerprints.json"))
        restoreBookmark()
        if isEnabled { startMonitoring() }
    }

    func chooseFolder(_ url: URL) throws {
        stopAccessingFolder()
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        folderURL = url
        accessingSecurityScope = url.startAccessingSecurityScopedResource()
        isEnabled = true
        lastImportError = nil
    }

    func clearFolder() {
        isEnabled = false
        stopAccessingFolder()
        folderURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    func checkNow() {
        guard isEnabled else { return }
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            await self?.pollOnce()
            self?.startMonitoring()
        }
    }

    @discardableResult
    func importAgain(_ url: URL) async throws -> DraftBatch {
        guard let folderURL else { throw WatchedFolderError.folderUnavailable }
        guard url.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL else {
            throw WatchedFolderError.outsideWatchedFolder
        }
        guard draftStore.actionableCount < 20 else { throw DraftStoreError.draftLimitReached }
        let candidate = try await tracker.explicitCandidate(for: url)
        status = .importing
        do {
            let batch = try await draftStore.importWatchedFile(url)
            try await tracker.markImported(candidate)
            importedCount += 1
            lastImportError = nil
            status = .watching
            return batch
        } catch {
            let safeError = safeImportError(error)
            lastImportError = safeError
            status = .paused(safeError)
            throw error
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            folderURL = url
            accessingSecurityScope = url.startAccessingSecurityScopedResource()
            if stale {
                let refreshed = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
        } catch {
            status = .paused(WatchedFolderError.permissionLost.localizedDescription)
            lastImportError = WatchedFolderError.permissionLost.localizedDescription
        }
    }

    private func startMonitoring() {
        guard isEnabled, folderURL != nil, monitorTask == nil else {
            if isEnabled && folderURL == nil {
                status = .paused(String(localized: "Choose a folder to resume."))
            }
            return
        }
        status = .watching
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        status = .disabled
    }

    private func pollOnce() async {
        guard let folderURL, isEnabled else { return }
        do {
            let candidates = try await tracker.stableCandidates(in: folderURL)
            for candidate in candidates {
                guard draftStore.actionableCount < 20 else {
                    status = .paused(String(localized: "Draft limit reached; watched-folder intake is paused."))
                    return
                }
                status = .importing
                do {
                    _ = try await draftStore.importWatchedFile(candidate.url)
                    try await tracker.markImported(candidate)
                    importedCount += 1
                    lastImportError = nil
                } catch {
                    let safeError = safeImportError(error)
                    lastImportError = safeError
                    status = .paused(safeError)
                    return
                }
            }
            status = .watching
        } catch {
            let safeError = safeImportError(error)
            lastImportError = safeError
            status = .paused(safeError)
        }
    }

    private func safeImportError(_ error: Error) -> String {
        if let error = error as? WatchedFolderError { return error.localizedDescription }
        if let error = error as? DraftStoreError { return error.localizedDescription }
        return String(localized: "The file could not be imported safely. Its source was left untouched; check folder access and try again.")
    }

    private func stopAccessingFolder() {
        if accessingSecurityScope { folderURL?.stopAccessingSecurityScopedResource() }
        accessingSecurityScope = false
    }
}
