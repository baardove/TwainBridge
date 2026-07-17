import XCTest
@testable import TwainBridge

final class DraftRepositoryTests: XCTestCase {
    func testLegacyBatchWithoutLibraryFlagMigratesIntoLibrary() throws {
        let now = Date()
        let batch = DraftBatch(
            id: UUID(),
            documents: [],
            destinationID: nil,
            state: .ready,
            createdAt: now,
            updatedAt: now,
            lastErrorCategory: nil
        )
        let encoded = try JSONEncoder().encode(batch)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isStoredInLibrary")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DraftBatch.self, from: legacy)

        XCTAssertTrue(decoded.isStoredInLibrary)
    }

    func testCaptureOriginDistinguishesScannerWebcamAndWatchedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x23, count: 1_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 8, count: 32))

        func result(scannerID: String) -> CompletedScanResult {
            CompletedScanResult(
                id: UUID(),
                pageURLs: [source],
                request: .init(scannerID: scannerID, source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
                scannerName: "Capture Device",
                completedAt: Date(),
                interrupted: false
            )
        }

        let scannerBatch = try await repository.importScan(result(scannerID: "scanner-1"))
        let webcamBatch = try await repository.importScan(result(scannerID: "webcam:camera-1"))
        let watchedBatch = try await repository.importScan(result(scannerID: "watched-folder"))
        XCTAssertEqual(scannerBatch.captureOrigin, .scanner)
        XCTAssertEqual(webcamBatch.captureOrigin, .webcam)
        XCTAssertEqual(watchedBatch.captureOrigin, .watchedFolder)
    }

    func testDraftManifestIsEncryptedAndAuthenticatedAtRest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming.tiff")
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 2_000).write(to: incoming)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x22, count: 32)
        let repository = try DraftRepository(rootURL: store, keyData: key)
        var batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Private Scanner Name",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].name = "Private Customer Filename"
        batch.metadata["case"] = "Secret Case Metadata"
        try await repository.save(batch)

        let manifest = store.appendingPathComponent("Drafts")
            .appendingPathComponent(batch.id.uuidString)
            .appendingPathExtension("tbmanifest")
        let encrypted = try Data(contentsOf: manifest)
        let visible = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(visible.contains("Private Customer Filename"))
        XCTAssertFalse(visible.contains("Secret Case Metadata"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: manifest.deletingPathExtension().appendingPathExtension("json").path
        ))
        let reloaded = try await repository.loadBatches()
        XCTAssertEqual(reloaded.first?.documents.first?.name, "Private Customer Filename")

        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: manifest, options: .atomic)
        do {
            _ = try await repository.loadBatches()
            XCTFail("Tampered metadata must not load")
        } catch {
            XCTAssertTrue(error is EncryptedManifestStoreError)
        }
    }

    func testLegacyPlaintextManifestMigratesToEncryptedStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("store")
        let drafts = store.appendingPathComponent("Drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let batch = DraftBatch(
            id: UUID(),
            documents: [],
            destinationID: nil,
            state: .ready,
            createdAt: now,
            updatedAt: now,
            lastErrorCategory: nil,
            metadata: ["legacy": "private value"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyURL = drafts.appendingPathComponent(batch.id.uuidString).appendingPathExtension("json")
        try encoder.encode(batch).write(to: legacyURL, options: .atomic)

        let repository = try DraftRepository(rootURL: store, keyData: Data(repeating: 0x33, count: 32))
        let loaded = try await repository.loadBatches()
        let encryptedURL = drafts.appendingPathComponent(batch.id.uuidString).appendingPathExtension("tbmanifest")

        XCTAssertEqual(loaded.first?.metadata["legacy"], "private value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
        XCTAssertFalse(String(decoding: try Data(contentsOf: encryptedURL), as: UTF8.self).contains("private value"))
        let reloaded = try await repository.loadBatches()
        XCTAssertEqual(reloaded.first?.id, batch.id)
    }

    func testManifestWithoutCompressionPresetRemainsDecodable() throws {
        let now = Date()
        let document = DraftDocument(
            id: UUID(),
            name: "Legacy",
            pages: [],
            scanSettings: ScanSettingsSnapshot(
                scannerID: "scanner",
                scannerName: "Scanner",
                source: .flatbed,
                colorMode: .color,
                resolution: 300,
                duplex: false
            ),
            outputFormat: .pdf,
            compressionPreset: nil,
            metadata: [:],
            transfer: .init(),
            createdAt: now,
            updatedAt: now
        )
        let data = try JSONEncoder().encode(document)
        XCTAssertNil(try JSONDecoder().decode(DraftDocument.self, from: data).compressionPreset)
    }

    func testSendAgainCreatesIndependentEncryptedCopyWithFreshIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8_000).write(to: incoming)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 6, count: 32)
        )
        var original = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        original.state = .sent
        try await repository.save(original)
        let copy = try await repository.duplicateForSendAgain(original)

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.logicalBatchID, original.logicalBatchID)
        XCTAssertNotEqual(copy.documents[0].id, original.documents[0].id)
        XCTAssertNotEqual(copy.documents[0].pages[0].id, original.documents[0].pages[0].id)
        XCTAssertFalse(copy.documents[0].transfer.confirmed)
        XCTAssertEqual(copy.state, .ready)
        XCTAssertTrue(copy.isStoredInLibrary)
        try await repository.deleteBatch(original.id)
        let materialized = try await repository.materializePage(
            batchID: copy.id,
            documentID: copy.documents[0].id,
            page: copy.documents[0].pages[0]
        )
        XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: incoming))
        await repository.deleteMaterializedFile(materialized)
    }

    func testSinglePageOverflowSplitPreservesEncryptedPagesAndCreatesDocumentIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = (1...3).map { incoming.appendingPathComponent("page-\($0).tiff") }
        for (index, page) in pages.enumerated() {
            try Data(repeating: UInt8(index + 1), count: 4_000 + index).write(to: page)
        }
        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 7, count: 32)
        )
        let batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: pages,
            request: .init(scannerID: "scanner", source: .documentFeeder, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        let originalDocumentID = batch.documents[0].id
        let originalPageIDs = batch.documents[0].pages.map(\.id)
        let (split, mapping) = try await repository.splitDocumentsIntoSinglePages(batch)

        XCTAssertEqual(split.documents.count, 3)
        XCTAssertEqual(split.documents.map { $0.pages.count }, [1, 1, 1])
        XCTAssertEqual(split.documents.map { $0.pages[0].id }, originalPageIDs)
        XCTAssertEqual(mapping[originalDocumentID]?.count, 3)
        XCTAssertEqual(Set(split.documents.map(\.id)).count, 3)
        for (index, document) in split.documents.enumerated() {
            let materialized = try await repository.materializePage(
                batchID: split.id,
                documentID: document.id,
                page: document.pages[0]
            )
            XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: pages[index]))
            await repository.deleteMaterializedFile(materialized)
        }
        let reloaded = try await repository.loadBatches()
        XCTAssertEqual(reloaded.first?.documents.count, 3)
    }

    func testImportedScanIsEncryptedPersistentAndMaterializable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = source.appendingPathComponent("page-1.tiff")
        let second = source.appendingPathComponent("page-2.tiff")
        try Data(repeating: 11, count: 5_000).write(to: first)
        try Data(repeating: 19, count: 7_000).write(to: second)

        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 9, count: 32))
        let result = CompletedScanResult(
            id: UUID(),
            pageURLs: [first, second],
            request: ScanRequest(
                scannerID: "scanner-1",
                source: .documentFeeder,
                colorMode: .color,
                resolution: 300,
                duplex: true
            ),
            scannerName: "Test Scanner",
            completedAt: Date(),
            interrupted: false
        )

        let batch = try await repository.importScan(result)
        XCTAssertEqual(batch.pageCount, 2)
        XCTAssertEqual(batch.state, .ready)

        let loaded = try await repository.loadBatches()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, batch.id)
        XCTAssertEqual(loaded.first?.pageCount, 2)
        XCTAssertEqual(loaded.first?.documents.first?.scanSettings, batch.documents.first?.scanSettings)

        let page = try XCTUnwrap(batch.documents.first?.pages.first)
        let materialized = try await repository.materializePage(
            batchID: batch.id,
            documentID: batch.documents[0].id,
            page: page
        )
        XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: first))
        await repository.deleteMaterializedFile(materialized)
    }

    func testReloadRemovesOnlyPayloadsNotReferencedByCommittedManifests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 4_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = try DraftRepository(rootURL: store, keyData: Data(repeating: 0x17, count: 32))
        let batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [source],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        let document = try XCTUnwrap(batch.documents.first)
        let payloadRoot = store.appendingPathComponent("Payloads")
        let validDocumentDirectory = payloadRoot
            .appendingPathComponent(batch.id.uuidString)
            .appendingPathComponent(document.id.uuidString)
        let orphanPage = validDocumentDirectory.appendingPathComponent("orphan.tbpage")
        try Data("orphan".utf8).write(to: orphanPage)
        let orphanDocument = payloadRoot
            .appendingPathComponent(batch.id.uuidString)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphanDocument, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphanDocument.appendingPathComponent("orphan.tbpage"))
        let orphanBatch = payloadRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphanBatch, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphanBatch.appendingPathComponent("orphan.tbpage"))

        _ = try await repository.loadBatches()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDocument.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBatch.path))
        let materialized = try await repository.materializePage(
            batchID: batch.id,
            documentID: document.id,
            page: document.pages[0]
        )
        XCTAssertEqual(try Data(contentsOf: materialized), try Data(contentsOf: source))
        await repository.deleteMaterializedFile(materialized)
    }

    func testUploadingDraftRecoversAsFailedAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DraftRepository(rootURL: root, keyData: Data(repeating: 5, count: 32))
        let now = Date()
        var batch = DraftBatch(
            id: UUID(),
            documents: [],
            destinationID: nil,
            state: .uploading,
            createdAt: now,
            updatedAt: now,
            lastErrorCategory: nil
        )
        try await repository.save(batch)

        let recoveredBatches = try await repository.loadBatches()
        batch = try XCTUnwrap(recoveredBatches.first)
        XCTAssertEqual(batch.state, .failed)
        XCTAssertEqual(batch.lastErrorCategory, "operation_interrupted")
    }

    func testScansCanAppendCreateAndReplaceExplicitDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = incoming.appendingPathComponent("page.tiff")
        try Data(repeating: 4, count: 1_000).write(to: page)
        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 2, count: 32))

        func result(resolution: Int) -> CompletedScanResult {
            CompletedScanResult(
                id: UUID(),
                pageURLs: [page],
                request: ScanRequest(
                    scannerID: "scanner",
                    source: .documentFeeder,
                    colorMode: .grayscale,
                    resolution: resolution,
                    duplex: false
                ),
                scannerName: "Scanner",
                completedAt: Date(),
                interrupted: false
            )
        }

        var batch = try await repository.importScan(result(resolution: 200))
        let firstDocumentID = try XCTUnwrap(batch.documents.first?.id)
        batch = try await repository.importScan(
            result(resolution: 300),
            existingBatch: batch,
            target: .appendPages(batchID: batch.id, documentID: firstDocumentID)
        )
        XCTAssertEqual(batch.documents.count, 1)
        XCTAssertEqual(batch.documents[0].pages.count, 2)
        XCTAssertEqual(batch.documents[0].pages[1].scanSettings?.resolution, 300)

        batch = try await repository.importScan(
            result(resolution: 600),
            existingBatch: batch,
            target: .newDocument(batchID: batch.id)
        )
        XCTAssertEqual(batch.documents.count, 2)

        batch = try await repository.importScan(
            result(resolution: 150),
            existingBatch: batch,
            target: .replaceDocument(batchID: batch.id, documentID: firstDocumentID)
        )
        XCTAssertEqual(batch.documents.count, 2)
        XCTAssertEqual(batch.documents[0].id, firstDocumentID)
        XCTAssertEqual(batch.documents[0].pages.count, 1)
        XCTAssertEqual(batch.documents[0].pages[0].scanSettings?.resolution, 150)
    }

    func testDeletingBatchRemovesManifestAndMakesEncryptedPayloadUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        let store = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 2_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try DraftRepository(rootURL: store, keyData: Data(repeating: 0x31, count: 32))
        let batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [source],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        let document = try XCTUnwrap(batch.documents.first)
        let page = try XCTUnwrap(document.pages.first)
        let manifest = store.appendingPathComponent("Drafts/\(batch.id.uuidString).tbmanifest")
        let payloadDirectory = store.appendingPathComponent("Payloads/\(batch.id.uuidString)")

        try await repository.deleteBatch(batch.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadDirectory.path))
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.materializePage(
                batchID: batch.id,
                documentID: document.id,
                page: page
            )
        }
    }

    @MainActor
    func testTwentyActionableDraftLimitRejectsWithoutDeletingSourceAndReopensAfterSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 0x15, count: 32))
        await store.reload()
        let result = CompletedScanResult(
            id: UUID(),
            pageURLs: [source],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        )
        for _ in 0..<20 { _ = try await store.importCompletedScan(result) }
        XCTAssertEqual(store.actionableCount, 20)

        do {
            _ = try await store.importCompletedScan(result)
            XCTFail("The twenty-first actionable draft must be rejected")
        } catch DraftStoreError.draftLimitReached {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let sentID = try XCTUnwrap(store.batches.last?.id)
        try await store.setBatchState(.sent, batchID: sentID)
        _ = try await store.importCompletedScan(result)
        XCTAssertEqual(store.actionableCount, 20)
    }

    @MainActor
    func testBackgroundImportDoesNotStealActivePreviewSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x33, count: 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 0x21, count: 32))
        await store.reload()
        let result = CompletedScanResult(
            id: UUID(),
            pageURLs: [source],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        )
        let foreground = try await store.importCompletedScan(result)
        XCTAssertEqual(store.selectedBatchID, foreground.id)

        let background = try await store.importCompletedScan(result, selectImportedBatch: false)

        XCTAssertNotEqual(background.id, foreground.id)
        XCTAssertEqual(store.selectedBatchID, foreground.id)
        XCTAssertEqual(store.batches.first?.id, background.id)
    }

    @MainActor
    func testLibraryPreferencePersistsAndControlsNewCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("page.tiff")
        let suiteName = "TwainBridge.LibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x52, count: 1_024).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = DraftStore(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 0x19, count: 32),
            defaults: defaults
        )
        await store.reload()
        XCTAssertTrue(store.keepNewCapturesInLibrary)
        store.setKeepNewCapturesInLibrary(false)
        let batch = try await store.importCompletedScan(.init(
            id: UUID(),
            pageURLs: [source],
            request: .init(scannerID: "webcam:test", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Webcam",
            completedAt: Date(),
            interrupted: false
        ))

        XCTAssertFalse(batch.isStoredInLibrary)
        let reloadedPreference = DraftStore(
            rootURL: root.appendingPathComponent("other-store"),
            keyData: Data(repeating: 0x20, count: 32),
            defaults: defaults
        )
        await reloadedPreference.reload()
        XCTAssertFalse(reloadedPreference.keepNewCapturesInLibrary)
    }

    @MainActor
    func testRetentionAndTemporaryCleanupPreserveLibraryItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x29, count: 32)
        let repository = try DraftRepository(rootURL: storage, keyData: key)
        let old = Date(timeIntervalSinceNow: -7_200)
        let kept = DraftBatch(
            id: UUID(), documents: [], destinationID: nil, state: .sent,
            createdAt: old, updatedAt: old, lastErrorCategory: nil, isStoredInLibrary: true
        )
        let temporary = DraftBatch(
            id: UUID(), documents: [], destinationID: nil, state: .sent,
            createdAt: old, updatedAt: old, lastErrorCategory: nil, isStoredInLibrary: false
        )
        try await repository.save(kept)
        try await repository.save(temporary)
        let store = DraftStore(rootURL: storage, keyData: key)
        await store.reload()

        await store.cleanupExpired(retentionHours: 1, sentGraceMinutes: 1)

        XCTAssertEqual(store.batches.map(\.id), [kept.id])
        await store.clearTemporaryDocuments()
        XCTAssertEqual(store.batches.map(\.id), [kept.id])
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
