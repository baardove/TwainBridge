import Foundation

@MainActor
final class DraftStore: ObservableObject {
    @Published private(set) var batches: [DraftBatch] = []
    @Published var selectedBatchID: UUID?
    @Published private(set) var isLoading = true
    @Published private(set) var lastError: String?
    @Published var nextScanTarget: DraftInsertionTarget = .newBatch
    @Published private(set) var keepNewCapturesInLibrary: Bool
    var preferredDestinationID: UUID?

    private let repository: DraftRepository?
    private let initializationError: Error?
    private let defaults: UserDefaults
    private let maximumActionableDrafts = 20
    private static let keepNewCapturesKey = "library.keepNewCaptures"

    init(rootURL: URL? = nil, keyData: Data? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepNewCapturesInLibrary = defaults.object(forKey: Self.keepNewCapturesKey) as? Bool ?? true
        do {
            let resolvedRoot = try rootURL ?? Self.defaultRootURL()
            let resolvedKey = try keyData ?? InstallationKeyProvider.loadOrCreate(encryptedDraftRootURL: resolvedRoot)
            repository = try DraftRepository(
                rootURL: resolvedRoot,
                keyData: resolvedKey,
                documentDefaults: DocumentCreationDefaults(defaults: defaults)
            )
            initializationError = nil
        } catch {
            repository = nil
            initializationError = error
        }

        Task { await reload() }
    }

    var selectedBatch: DraftBatch? {
        guard let selectedBatchID else { return batches.first }
        return batches.first { $0.id == selectedBatchID }
    }

    var actionableCount: Int {
        batches.filter { $0.state != .sent }.count
    }

    func reload() async {
        defer { isLoading = false }
        guard let repository else {
            lastError = initializationError?.localizedDescription ?? String(localized: "Draft storage is unavailable.")
            return
        }
        do {
            batches = try await repository.loadBatches()
            if selectedBatchID == nil { selectedBatchID = batches.first?.id }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func importCompletedScan(
        _ result: CompletedScanResult,
        selectImportedBatch: Bool = true
    ) async throws -> DraftBatch {
        if case .newBatch = nextScanTarget {
            guard actionableCount < maximumActionableDrafts else { throw DraftStoreError.draftLimitReached }
        }
        guard let repository else {
            throw DraftStoreError.initializationFailed(
                initializationError?.localizedDescription ?? "Unknown storage error"
            )
        }
        do {
            let previousSelection = selectedBatchID
            let existingBatch: DraftBatch? = switch nextScanTarget {
            case .newBatch: nil
            case let .appendPages(batchID, _), let .newDocument(batchID), let .replaceDocument(batchID, _):
                batches.first { $0.id == batchID }
            }
            let target = nextScanTarget
            let batch = try await repository.importScan(
                result,
                existingBatch: existingBatch,
                target: target,
                preferredDestinationID: preferredDestinationID,
                storeInLibrary: keepNewCapturesInLibrary
            )
            batches.removeAll { $0.id == batch.id }
            batches.insert(batch, at: 0)
            if selectImportedBatch || previousSelection == nil {
                selectedBatchID = batch.id
            } else {
                selectedBatchID = previousSelection
            }
            nextScanTarget = .newBatch
            lastError = nil
            return batch
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func importWatchedFile(_ sourceURL: URL) async throws -> DraftBatch {
        guard actionableCount < maximumActionableDrafts else { throw DraftStoreError.draftLimitReached }
        guard let repository else {
            throw DraftStoreError.initializationFailed(
                initializationError?.localizedDescription ?? String(localized: "Unknown storage error")
            )
        }
        let sourceBytes = Int64(
            (try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        let extractionEstimate = sourceBytes > Int64.max / 2 ? Int64.max : sourceBytes * 2
        try await repository.verifyDiskCapacity(requiredBytes: extractionEstimate)
        let extracted = try WatchedFilePageExtractor.extract(sourceURL)
        defer { WatchedFilePageExtractor.cleanup(extracted) }
        let result = CompletedScanResult(
            id: UUID(),
            pageURLs: extracted.pageURLs,
            request: ScanRequest(
                scannerID: "watched-folder",
                source: .automatic,
                colorMode: .color,
                resolution: 300,
                duplex: false
            ),
            scannerName: String(localized: "Watched Folder"),
            completedAt: Date(),
            interrupted: false
        )
        let savedTarget = nextScanTarget
        nextScanTarget = .newBatch
        defer { nextScanTarget = savedTarget }
        return try await importCompletedScan(result, selectImportedBatch: false)
    }

    func rotatePage(batchID: UUID, documentID: UUID, pageID: UUID, clockwise: Bool) async throws {
        try await mutateBatch(batchID) { batch in
            guard let documentIndex = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            guard !batch.documents[documentIndex].transfer.confirmed else {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
            guard let pageIndex = batch.documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
                throw DraftStoreError.pageNotFound
            }
            let current = batch.documents[documentIndex].pages[pageIndex].rotation
            batch.documents[documentIndex].pages[pageIndex].rotation = clockwise
                ? current.rotatedClockwise()
                : current.rotatedCounterClockwise()
            batch.documents[documentIndex].updatedAt = Date()
        }
    }

    func movePage(batchID: UUID, documentID: UUID, from offsets: IndexSet, to destination: Int) async throws {
        try await mutateBatch(batchID) { batch in
            guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            guard !batch.documents[index].transfer.confirmed else {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
            batch.documents[index].pages.move(fromOffsets: offsets, toOffset: destination)
            batch.documents[index].updatedAt = Date()
        }
    }

    func renameDocument(batchID: UUID, documentID: UUID, name: String) async throws {
        try await mutateBatch(batchID) { batch in
            guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            guard !batch.documents[index].transfer.confirmed else {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            batch.documents[index].name = trimmed.isEmpty
                ? String(localized: "Untitled Document")
                : String(trimmed.prefix(180))
            batch.documents[index].updatedAt = Date()
        }
    }

    func setOutputFormat(batchID: UUID, documentID: UUID, format: DocumentOutputFormat) async throws {
        try await mutateBatch(batchID) { batch in
            guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            guard !batch.documents[index].transfer.confirmed else {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
            if format == .jpeg, batch.documents[index].pages.count != 1 {
                throw OutputAssemblyError.jpegRequiresSinglePage
            }
            batch.documents[index].outputFormat = format
            batch.documents[index].updatedAt = Date()
        }
        defaults.set(format.rawValue, forKey: "document.defaultOutputFormat")
        await repository?.updateDocumentCreationDefaults(DocumentCreationDefaults(defaults: defaults))
    }

    func setCompressionPreset(
        batchID: UUID,
        documentID: UUID,
        preset: OutputCompressionPreset?
    ) async throws {
        try await mutateBatch(batchID) { batch in
            guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            guard !batch.documents[index].transfer.confirmed else {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
            batch.documents[index].compressionPreset = preset
            batch.documents[index].updatedAt = Date()
            if batch.lastErrorCategory == "output_size_exceeded" {
                batch.lastErrorCategory = nil
                batch.state = .ready
            }
        }
        defaults.set(preset?.rawValue ?? "", forKey: "document.defaultCompressionPreset")
        await repository?.updateDocumentCreationDefaults(DocumentCreationDefaults(defaults: defaults))
    }

    func moveDocument(batchID: UUID, from offsets: IndexSet, to destination: Int) async throws {
        try await mutateBatch(batchID) { batch in
            batch.documents.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    func deleteDocument(batchID: UUID, documentID: UUID) async throws {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let batchIndex = batches.firstIndex(where: { $0.id == batchID }),
              let documentIndex = batches[batchIndex].documents.firstIndex(where: { $0.id == documentID }) else {
            throw DraftStoreError.documentNotFound
        }
        guard !batches[batchIndex].documents[documentIndex].transfer.confirmed else {
            throw DraftStoreError.confirmedDocumentReadOnly
        }
        if batches[batchIndex].documents.count == 1 {
            try await discardBatch(batchID)
            return
        }
        var changed = batches[batchIndex]
        changed.documents.remove(at: documentIndex)
        changed.updatedAt = Date()
        try await repository.save(changed)
        batches[batchIndex] = changed
        try? await repository.deleteDocumentPayload(batchID: batchID, documentID: documentID)
    }

    func setMetadata(
        batchID: UUID,
        documentID: UUID?,
        key: String,
        value: String
    ) async throws {
        try await mutateBatch(batchID) { batch in
            if let documentID {
                guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else {
                    throw DraftStoreError.documentNotFound
                }
                guard !batch.documents[index].transfer.confirmed else {
                    throw DraftStoreError.confirmedDocumentReadOnly
                }
                batch.documents[index].metadata[key] = value
                batch.documents[index].updatedAt = Date()
            } else {
                batch.metadata[key] = value
            }
        }
    }

    func deletePage(batchID: UUID, documentID: UUID, pageID: UUID) async throws {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let batchIndex = batches.firstIndex(where: { $0.id == batchID }),
              let documentIndex = batches[batchIndex].documents.firstIndex(where: { $0.id == documentID }),
              let pageIndex = batches[batchIndex].documents[documentIndex].pages.firstIndex(where: { $0.id == pageID }) else {
            throw DraftStoreError.pageNotFound
        }
        guard !batches[batchIndex].documents[documentIndex].transfer.confirmed else {
            throw DraftStoreError.confirmedDocumentReadOnly
        }
        let page = batches[batchIndex].documents[documentIndex].pages[pageIndex]
        if batches[batchIndex].documents.count == 1,
           batches[batchIndex].documents[documentIndex].pages.count == 1 {
            try await discardBatch(batchID)
            return
        }
        var changed = batches[batchIndex]
        changed.documents[documentIndex].pages.remove(at: pageIndex)
        changed.documents[documentIndex].updatedAt = Date()
        changed.updatedAt = Date()
        if changed.documents[documentIndex].pages.isEmpty {
            changed.documents.remove(at: documentIndex)
        }
        try await repository.save(changed)
        batches[batchIndex] = changed
        try? await repository.deletePagePayload(batchID: batchID, documentID: documentID, page: page)
    }

    func discardBatch(_ batchID: UUID) async throws {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        try await repository.deleteBatch(batchID)
        batches.removeAll { $0.id == batchID }
        if selectedBatchID == batchID { selectedBatchID = batches.first?.id }
    }

    func materializePage(batchID: UUID, documentID: UUID, page: DraftPage) async throws -> URL {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        return try await repository.materializePage(batchID: batchID, documentID: documentID, page: page)
    }

    func releaseMaterializedPage(_ url: URL) async {
        await repository?.deleteMaterializedFile(url)
    }

    func prepareOutputs(
        batchID: UUID,
        filenamePattern: String? = nil,
        documentIDs: Set<UUID>? = nil,
        includeConfirmed: Bool = false
    ) async throws -> [PreparedDocument] {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let batch = batches.first(where: { $0.id == batchID }) else { throw DraftStoreError.draftNotFound }
        return try await repository.prepareOutputs(
            for: batch,
            filenamePattern: filenamePattern,
            documentIDs: documentIDs,
            includeConfirmed: includeConfirmed
        )
    }

    var libraryBatches: [DraftBatch] {
        batches.filter(\.isStoredInLibrary)
    }

    var libraryByteCount: Int64 {
        libraryBatches.reduce(0) { $0 + $1.originalByteCount }
    }

    func setKeepNewCapturesInLibrary(_ keep: Bool) {
        keepNewCapturesInLibrary = keep
        defaults.set(keep, forKey: Self.keepNewCapturesKey)
    }

    func setStoredInLibrary(_ stored: Bool, batchID: UUID) async throws {
        try await mutateBatch(batchID) { batch in
            batch.isStoredInLibrary = stored
        }
    }

    /// Removes a completed item and its encrypted payloads. Actionable items are
    /// only removed from the library and continue to exist as ordinary drafts.
    func removeFromLibrary(batchID: UUID) async throws {
        guard let batch = batches.first(where: { $0.id == batchID }) else {
            throw DraftStoreError.draftNotFound
        }
        if batch.state == .sent {
            try await discardBatch(batchID)
        } else {
            try await setStoredInLibrary(false, batchID: batchID)
        }
    }

    @discardableResult
    func duplicateForSendAgain(batchID: UUID) async throws -> DraftBatch {
        guard actionableCount < maximumActionableDrafts else { throw DraftStoreError.draftLimitReached }
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let source = batches.first(where: { $0.id == batchID }), source.state == .sent else {
            throw DraftStoreError.draftNotFound
        }
        let copy = try await repository.duplicateForSendAgain(source)
        batches.insert(copy, at: 0)
        selectedBatchID = copy.id
        return copy
    }

    func splitDocumentsIntoSinglePages(batchID: UUID) async throws -> [UUID: [UUID]] {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw DraftStoreError.draftNotFound
        }
        let (batch, mapping) = try await repository.splitDocumentsIntoSinglePages(batches[index])
        batches[index] = batch
        return mapping
    }

    func cleanupPreparedOutputs(_ outputs: [PreparedDocument]) async {
        await repository?.cleanupPreparedOutputs(outputs)
    }

    func setBatchState(_ state: DraftState, batchID: UUID, errorCategory: String? = nil) async throws {
        try await mutateBatch(batchID) { batch in
            batch.state = state
            batch.lastErrorCategory = errorCategory
        }
    }

    func assignDestination(_ destinationID: UUID?, batchID: UUID, resetLogicalBatchID: Bool = false) async throws {
        try await mutateBatch(batchID) { batch in
            batch.destinationID = destinationID
            if resetLogicalBatchID {
                batch.logicalBatchID = UUID()
                for index in batch.documents.indices where !batch.documents[index].transfer.confirmed {
                    batch.documents[index].transfer = DocumentTransferState()
                }
            }
        }
    }

    func recordUploadResult(_ result: UploadDocumentResult, batchID: UUID) async throws {
        try await mutateBatch(batchID) { batch in
            guard let index = batch.documents.firstIndex(where: { $0.id == result.documentID }) else {
                throw DraftStoreError.documentNotFound
            }
            if let requestID = result.requestID {
                batch.documents[index].transfer.lastRequestID = requestID
            }
            batch.documents[index].transfer.lastStatusCode = result.statusCode
            batch.documents[index].transfer.lastAttemptAt = Date()
            batch.documents[index].transfer.attemptCount = max(
                batch.documents[index].transfer.attemptCount,
                result.attemptCount
            )
            batch.documents[index].transfer.sanitizedError = result.confirmation == .confirmed ? nil : result.message
            if result.confirmation == .confirmed {
                batch.documents[index].transfer.confirmed = true
                batch.documents[index].transfer.remoteID = result.remoteID
                batch.documents[index].transfer.openURL = result.openURL
            }
        }
    }

    func recordUploadAttempt(_ event: UploadAttemptEvent, batchID: UUID) async throws {
        try await mutateBatch(batchID) { batch in
            for documentID in event.documentIDs {
                guard let index = batch.documents.firstIndex(where: { $0.id == documentID }) else { continue }
                let record = UploadAttemptRecord(
                    requestID: event.requestID,
                    attemptedAt: event.attemptedAt,
                    statusCode: event.statusCode,
                    outcome: event.outcome
                )
                batch.documents[index].transfer.attempts.append(record)
                if batch.documents[index].transfer.attempts.count > 20 {
                    batch.documents[index].transfer.attempts.removeFirst(
                        batch.documents[index].transfer.attempts.count - 20
                    )
                }
                batch.documents[index].transfer.lastRequestID = event.requestID
                batch.documents[index].transfer.lastStatusCode = event.statusCode
                batch.documents[index].transfer.lastAttemptAt = event.attemptedAt
                batch.documents[index].transfer.attemptCount = max(
                    batch.documents[index].transfer.attemptCount,
                    event.attemptNumber
                )
            }
        }
    }

    func removeConfirmedDocuments(batchID: UUID) async throws {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw DraftStoreError.draftNotFound
        }
        guard !batches[index].isStoredInLibrary else { return }
        let confirmed = batches[index].documents.filter(\.transfer.confirmed)
        var changed = batches[index]
        changed.documents.removeAll(where: \.transfer.confirmed)
        changed.updatedAt = Date()
        try await repository.save(changed)
        batches[index] = changed
        for document in confirmed {
            try? await repository.deleteDocumentPayload(batchID: batchID, documentID: document.id)
        }
    }

    func cleanupExpired(retentionHours: Int, sentGraceMinutes: Int = 5) async {
        let now = Date()
        let actionableCutoff = now.addingTimeInterval(-Double(max(retentionHours, 1)) * 3600)
        let sentCutoff = now.addingTimeInterval(-Double(max(sentGraceMinutes, 1)) * 60)
        let expired = batches.filter {
            !$0.isStoredInLibrary && (($0.state == .sent && $0.updatedAt < sentCutoff)
                || ($0.state != .sent && $0.updatedAt < actionableCutoff)
            )
        }.map(\.id)
        for id in expired { try? await discardBatch(id) }
    }

    func clearTemporaryDocuments() async {
        let removable = batches.filter {
            !$0.isStoredInLibrary && $0.state != .uploading && $0.state != .preparing
        }.map(\.id)
        for id in removable { try? await discardBatch(id) }
    }

    private func mutateBatch(_ batchID: UUID, mutation: (inout DraftBatch) throws -> Void) async throws {
        guard let repository else { throw DraftStoreError.initializationFailed(String(localized: "Storage is unavailable")) }
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else {
            throw DraftStoreError.draftNotFound
        }
        var changed = batches[index]
        try mutation(&changed)
        changed.updatedAt = Date()
        try await repository.save(changed)
        batches[index] = changed
        batches.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func defaultRootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport.appendingPathComponent("TwainBridge", isDirectory: true)
    }
}
