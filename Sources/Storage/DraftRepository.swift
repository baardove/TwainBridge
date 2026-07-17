import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DocumentCreationDefaults: Sendable {
    var outputFormat: DocumentOutputFormat
    var compressionPreset: OutputCompressionPreset?

    init(defaults: UserDefaults = .standard) {
        outputFormat = defaults.string(forKey: "document.defaultOutputFormat")
            .flatMap(DocumentOutputFormat.init(rawValue:)) ?? .pdf
        compressionPreset = defaults.string(forKey: "document.defaultCompressionPreset")
            .flatMap(OutputCompressionPreset.init(rawValue:))
    }
}

actor DraftRepository {
    let rootURL: URL
    private let keyData: Data
    private let draftsURL: URL
    private let payloadsURL: URL
    private let previewTempURL: URL
    private var documentDefaults: DocumentCreationDefaults

    init(
        rootURL: URL,
        keyData: Data,
        documentDefaults: DocumentCreationDefaults = .init()
    ) throws {
        self.rootURL = rootURL
        self.keyData = keyData
        self.documentDefaults = documentDefaults
        draftsURL = rootURL.appendingPathComponent("Drafts", isDirectory: true)
        payloadsURL = rootURL.appendingPathComponent("Payloads", isDirectory: true)
        previewTempURL = rootURL.appendingPathComponent("PreviewTemp", isDirectory: true)

        for directory in [rootURL, draftsURL, payloadsURL, previewTempURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
        }
        try Self.removeOrphanedPreviewFiles(at: previewTempURL)
    }

    func loadBatches() throws -> [DraftBatch] {
        let files = try FileManager.default.contentsOfDirectory(
            at: draftsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var batches: [DraftBatch] = []
        var loadedIDs: Set<UUID> = []
        let manifests = files
            .filter { ["tbmanifest", "json"].contains($0.pathExtension) }
            .sorted {
                ($0.pathExtension == "tbmanifest" ? 0 : 1)
                    < ($1.pathExtension == "tbmanifest" ? 0 : 1)
            }
        for file in manifests {
            guard let fileID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  loadedIDs.insert(fileID).inserted else { continue }
            let isLegacyPlaintext = file.pathExtension == "json"
            let data = isLegacyPlaintext
                ? try Data(contentsOf: file)
                : try EncryptedManifestStore.read(from: file, keyData: keyData)
            var batch = try decoder.decode(DraftBatch.self, from: data)
            guard batch.version == DraftBatch.manifestVersion else {
                throw DraftStoreError.unsupportedManifestVersion(batch.version)
            }

            if batch.state == .acquiring {
                batch.state = batch.pageCount > 0 ? .interrupted : .failed
                batch.lastErrorCategory = "acquisition_interrupted"
                batch.updatedAt = Date()
                try save(batch)
            } else if batch.state == .preparing || batch.state == .uploading {
                batch.state = .failed
                batch.lastErrorCategory = "operation_interrupted"
                batch.updatedAt = Date()
                try save(batch)
            }
            if isLegacyPlaintext {
                try save(batch)
                try? FileManager.default.removeItem(at: file)
            }
            batches.append(batch)
        }
        try removeOrphanedPayloads(keeping: batches)
        return batches.sorted { $0.updatedAt > $1.updatedAt }
    }

    func importScan(
        _ result: CompletedScanResult,
        existingBatch: DraftBatch? = nil,
        target: DraftInsertionTarget = .newBatch,
        preferredDestinationID: UUID? = nil,
        storeInLibrary: Bool = true
    ) throws -> DraftBatch {
        try verifyDiskCapacity(for: result.pageURLs)

        let now = Date()
        let batchID = existingBatch?.id ?? UUID()
        let documentID: UUID = switch target {
        case let .appendPages(_, documentID), let .replaceDocument(_, documentID): documentID
        case .newBatch, .newDocument: UUID()
        }
        switch target {
        case let .appendPages(_, targetDocumentID), let .replaceDocument(_, targetDocumentID):
            if existingBatch?.documents.first(where: { $0.id == targetDocumentID })?.transfer.confirmed == true {
                throw DraftStoreError.confirmedDocumentReadOnly
            }
        case .newBatch, .newDocument:
            break
        }
        let payloadDirectory = payloadDirectoryURL(batchID: batchID, documentID: documentID)
        try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloadDirectory.path)
        var createdPayloads: [URL] = []
        var succeeded = false
        defer {
            if !succeeded { createdPayloads.forEach { try? FileManager.default.removeItem(at: $0) } }
        }

        let settings = ScanSettingsSnapshot(
            scannerID: result.request.scannerID,
            scannerName: result.scannerName,
            source: result.request.source,
            colorMode: result.request.colorMode,
            resolution: result.request.resolution,
            duplex: result.request.duplex,
            pageSize: result.request.pageSize,
            orientation: result.request.orientation
        )

        var pages: [DraftPage] = []
        for source in result.pageURLs {
            let pageID = UUID()
            let filename = "\(pageID.uuidString).tbpage"
            let destination = payloadDirectory.appendingPathComponent(filename)
            try EncryptedFileStore.encrypt(source: source, destination: destination, keyData: keyData)
            createdPayloads.append(destination)
            pages.append(makePage(
                id: pageID,
                filename: filename,
                source: source,
                createdAt: now,
                scanSettings: settings
            ))
        }

        var batch: DraftBatch
        switch target {
        case .newBatch:
            let document = newDocument(id: documentID, pages: pages, settings: settings, now: now)
            batch = DraftBatch(
                id: batchID,
                documents: [document],
                destinationID: preferredDestinationID,
                state: result.interrupted ? .interrupted : .ready,
                createdAt: now,
                updatedAt: now,
                lastErrorCategory: result.interrupted ? "acquisition_interrupted" : nil,
                isStoredInLibrary: storeInLibrary
            )
        case let .appendPages(_, targetDocumentID):
            guard var existingBatch,
                  let index = existingBatch.documents.firstIndex(where: { $0.id == targetDocumentID }) else {
                throw DraftStoreError.documentNotFound
            }
            existingBatch.documents[index].pages.append(contentsOf: pages)
            existingBatch.documents[index].updatedAt = now
            existingBatch.state = result.interrupted ? .interrupted : .ready
            existingBatch.updatedAt = now
            existingBatch.lastErrorCategory = result.interrupted ? "acquisition_interrupted" : nil
            batch = existingBatch
        case .newDocument:
            guard var existingBatch else { throw DraftStoreError.draftNotFound }
            existingBatch.documents.append(newDocument(id: documentID, pages: pages, settings: settings, now: now))
            existingBatch.state = result.interrupted ? .interrupted : .ready
            existingBatch.updatedAt = now
            existingBatch.lastErrorCategory = result.interrupted ? "acquisition_interrupted" : nil
            batch = existingBatch
        case let .replaceDocument(_, targetDocumentID):
            guard var existingBatch,
                  let index = existingBatch.documents.firstIndex(where: { $0.id == targetDocumentID }) else {
                throw DraftStoreError.documentNotFound
            }
            let oldPages = existingBatch.documents[index].pages
            let oldName = existingBatch.documents[index].name
            var replacement = newDocument(id: documentID, pages: pages, settings: settings, now: now)
            replacement.name = oldName
            existingBatch.documents[index] = replacement
            existingBatch.state = result.interrupted ? .interrupted : .ready
            existingBatch.updatedAt = now
            existingBatch.lastErrorCategory = result.interrupted ? "acquisition_interrupted" : nil
            batch = existingBatch
            try save(batch)
            for oldPage in oldPages {
                try? deletePagePayload(batchID: batchID, documentID: targetDocumentID, page: oldPage)
            }
            succeeded = true
            return batch
        }
        try save(batch)
        succeeded = true
        return batch
    }

    func save(_ batch: DraftBatch) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(batch)
        try EncryptedManifestStore.write(data, to: manifestURL(for: batch.id), keyData: keyData)
        let legacy = legacyManifestURL(for: batch.id)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    func updateDocumentCreationDefaults(_ defaults: DocumentCreationDefaults) {
        documentDefaults = defaults
    }

    func duplicateForSendAgain(_ source: DraftBatch) throws -> DraftBatch {
        let encryptedSources = source.documents.flatMap { document in
            document.pages.map {
                payloadDirectoryURL(batchID: source.id, documentID: document.id)
                    .appendingPathComponent($0.encryptedFilename)
            }
        }
        try verifyDiskCapacity(for: encryptedSources)

        let now = Date()
        let batchID = UUID()
        let targetBatchDirectory = payloadsURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: targetBatchDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetBatchDirectory.path)
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: targetBatchDirectory) }
        }

        var documents: [DraftDocument] = []
        for document in source.documents {
            let documentID = UUID()
            let targetDirectory = payloadDirectoryURL(batchID: batchID, documentID: documentID)
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetDirectory.path)
            var pages: [DraftPage] = []
            for page in document.pages {
                let pageID = UUID()
                let filename = "\(pageID.uuidString).tbpage"
                let encryptedSource = payloadDirectoryURL(batchID: source.id, documentID: document.id)
                    .appendingPathComponent(page.encryptedFilename)
                try FileManager.default.copyItem(
                    at: encryptedSource,
                    to: targetDirectory.appendingPathComponent(filename)
                )
                var copiedPage = page
                copiedPage.id = pageID
                copiedPage.encryptedFilename = filename
                copiedPage.createdAt = now
                pages.append(copiedPage)
            }
            var copiedDocument = document
            copiedDocument.id = documentID
            copiedDocument.name = String(localized: "Copy of \(document.name)")
            copiedDocument.pages = pages
            copiedDocument.transfer = DocumentTransferState()
            copiedDocument.createdAt = now
            copiedDocument.updatedAt = now
            documents.append(copiedDocument)
        }
        let batch = DraftBatch(
            id: batchID,
            documents: documents,
            destinationID: source.destinationID,
            state: .ready,
            createdAt: now,
            updatedAt: now,
            lastErrorCategory: nil,
            metadata: source.metadata,
            isStoredInLibrary: source.isStoredInLibrary
        )
        try save(batch)
        succeeded = true
        return batch
    }

    func splitDocumentsIntoSinglePages(_ source: DraftBatch) throws -> (DraftBatch, [UUID: [UUID]]) {
        var batch = source
        var documents: [DraftDocument] = []
        var mapping: [UUID: [UUID]] = [:]
        var copiedDirectories: [URL] = []
        var copiedFiles: [(source: URL, copied: URL)] = []
        var saved = false
        defer {
            if !saved { copiedDirectories.forEach { try? FileManager.default.removeItem(at: $0) } }
        }

        for document in source.documents {
            guard document.pages.count > 1, !document.transfer.confirmed else {
                documents.append(document)
                mapping[document.id] = [document.id]
                continue
            }
            var first = document
            first.pages = [document.pages[0]]
            first.updatedAt = Date()
            documents.append(first)
            var documentIDs = [document.id]

            for (pageIndex, page) in document.pages.dropFirst().enumerated() {
                let newDocumentID = UUID()
                let targetDirectory = payloadDirectoryURL(batchID: source.id, documentID: newDocumentID)
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: targetDirectory.path)
                copiedDirectories.append(targetDirectory)
                let oldFile = payloadDirectoryURL(batchID: source.id, documentID: document.id)
                    .appendingPathComponent(page.encryptedFilename)
                let newFile = targetDirectory.appendingPathComponent(page.encryptedFilename)
                try FileManager.default.copyItem(at: oldFile, to: newFile)
                copiedFiles.append((oldFile, newFile))

                var split = document
                split.id = newDocumentID
                split.name = String(localized: "\(document.name) — Page \(pageIndex + 2)")
                split.pages = [page]
                split.transfer = DocumentTransferState()
                split.createdAt = Date()
                split.updatedAt = Date()
                documents.append(split)
                documentIDs.append(newDocumentID)
            }
            mapping[document.id] = documentIDs
        }
        batch.documents = documents
        batch.updatedAt = Date()
        try save(batch)
        saved = true
        for pair in copiedFiles { try? FileManager.default.removeItem(at: pair.source) }
        return (batch, mapping)
    }

    func materializePage(batchID: UUID, documentID: UUID, page: DraftPage) throws -> URL {
        let source = payloadDirectoryURL(batchID: batchID, documentID: documentID)
            .appendingPathComponent(page.encryptedFilename)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DraftStoreError.pageNotFound
        }
        let output = previewTempURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension(for: page.originalContentType))
        do {
            try EncryptedFileStore.decrypt(source: source, destination: output, keyData: keyData)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            return output
        } catch {
            throw DraftStoreError.corruptPayload
        }
    }

    func deleteMaterializedFile(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == previewTempURL.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func deletePagePayload(batchID: UUID, documentID: UUID, page: DraftPage) throws {
        let url = payloadDirectoryURL(batchID: batchID, documentID: documentID)
            .appendingPathComponent(page.encryptedFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteDocumentPayload(batchID: UUID, documentID: UUID) throws {
        let url = payloadDirectoryURL(batchID: batchID, documentID: documentID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteBatch(_ batchID: UUID) throws {
        let manifest = manifestURL(for: batchID)
        let legacyManifest = legacyManifestURL(for: batchID)
        let payload = payloadsURL.appendingPathComponent(batchID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path) {
            try FileManager.default.removeItem(at: manifest)
        }
        if FileManager.default.fileExists(atPath: legacyManifest.path) {
            try FileManager.default.removeItem(at: legacyManifest)
        }
        if FileManager.default.fileExists(atPath: payload.path) {
            try? FileManager.default.removeItem(at: payload)
        }
    }

    func prepareOutputs(
        for batch: DraftBatch,
        filenamePattern: String? = nil,
        documentIDs: Set<UUID>? = nil,
        includeConfirmed: Bool = false
    ) throws -> [PreparedDocument] {
        let estimatedBytes = batch.documents
            .filter { (includeConfirmed || !$0.transfer.confirmed) && (documentIDs?.contains($0.id) ?? true) }
            .flatMap(\.pages)
            .reduce(Int64(0)) { $0 + max($1.originalByteCount, 0) }
        try verifyDiskCapacity(requiredBytes: estimatedBytes)
        let operationDirectory = rootURL
            .appendingPathComponent("UploadTemp", isDirectory: true)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: operationDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: operationDirectory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = operationDirectory
        try? mutableDirectory.setResourceValues(values)

        var outputs: [PreparedDocument] = []
        do {
            var usedNames: Set<String> = []
            let documents = batch.documents.filter { document in
                (includeConfirmed || !document.transfer.confirmed)
                    && (documentIDs?.contains(document.id) ?? true)
            }
            for (index, document) in documents.enumerated() {
                let filename = uniqueFilename(
                    for: document,
                    batch: batch,
                    index: index,
                    pattern: filenamePattern,
                    used: &usedNames
                )
                let destination = operationDirectory.appendingPathComponent(filename)
                switch document.outputFormat {
                case .pdf:
                    try writePDF(document: document, batchID: batch.id, destination: destination)
                case .jpeg:
                    guard document.pages.count == 1 else {
                        throw OutputAssemblyError.jpegRequiresSinglePage
                    }
                    try writeJPEG(document: document, batchID: batch.id, destination: destination)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                outputs.append(.init(
                    id: document.id,
                    fileURL: destination,
                    filename: filename,
                    contentType: document.outputFormat.contentType,
                    byteCount: Int64(size),
                    pageCount: document.pages.count
                ))
            }
            return outputs
        } catch {
            try? FileManager.default.removeItem(at: operationDirectory)
            throw error
        }
    }

    func cleanupPreparedOutputs(_ outputs: [PreparedDocument]) {
        guard let directory = outputs.first?.fileURL.deletingLastPathComponent() else { return }
        let uploadRoot = rootURL.appendingPathComponent("UploadTemp", isDirectory: true).standardizedFileURL
        guard directory.standardizedFileURL.path.hasPrefix(uploadRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func verifyDiskCapacity(for sources: [URL]) throws {
        let required = try sources.reduce(Int64(0)) { result, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return result + Int64(values.fileSize ?? 0)
        }
        try verifyDiskCapacity(requiredBytes: required)
    }

    func verifyDiskCapacity(requiredBytes: Int64) throws {
        try DiskCapacityGuard.verify(at: rootURL, requiredBytes: requiredBytes)
    }

    private func makePage(
        id: UUID,
        filename: String,
        source: URL,
        createdAt: Date,
        scanSettings: ScanSettingsSnapshot
    ) -> DraftPage {
        let metadata = imageMetadata(for: source)
        let byteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        let contentType = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier)
            ?? UTType(filenameExtension: source.pathExtension)?.identifier
            ?? UTType.data.identifier
        return DraftPage(
            id: id,
            encryptedFilename: filename,
            originalContentType: contentType,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            physicalWidthPoints: metadata.physicalWidthPoints,
            physicalHeightPoints: metadata.physicalHeightPoints,
            rotation: .zero,
            originalByteCount: byteCount,
            createdAt: createdAt,
            scanSettings: scanSettings
        )
    }

    private func newDocument(
        id: UUID,
        pages: [DraftPage],
        settings: ScanSettingsSnapshot,
        now: Date
    ) -> DraftDocument {
        let configuredFormat = documentDefaults.outputFormat
        let outputFormat: DocumentOutputFormat = configuredFormat == .jpeg && pages.count != 1 ? .pdf : configuredFormat
        let compression = documentDefaults.compressionPreset
        return DraftDocument(
            id: id,
            name: String(localized: "Scan \(Self.documentDateFormatter.string(from: now))"),
            pages: pages,
            scanSettings: settings,
            outputFormat: outputFormat,
            compressionPreset: compression,
            metadata: [:],
            transfer: DocumentTransferState(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func imageMetadata(for url: URL) -> (pixelWidth: Int, pixelHeight: Int, physicalWidthPoints: Double, physicalHeightPoints: Double) {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true,
           let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            return (Int(box.width), Int(box.height), box.width, box.height)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0, 612, 792)
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let dpiWidth = max((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72, 1)
        let dpiHeight = max((properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? dpiWidth, 1)
        return (width, height, Double(width) / dpiWidth * 72, Double(height) / dpiHeight * 72)
    }

    private func manifestURL(for batchID: UUID) -> URL {
        draftsURL.appendingPathComponent(batchID.uuidString).appendingPathExtension("tbmanifest")
    }

    private func legacyManifestURL(for batchID: UUID) -> URL {
        draftsURL.appendingPathComponent(batchID.uuidString).appendingPathExtension("json")
    }

    private func payloadDirectoryURL(batchID: UUID, documentID: UUID) -> URL {
        payloadsURL
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    private static func removeOrphanedPreviewFiles(at previewTempURL: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: previewTempURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files { try FileManager.default.removeItem(at: file) }
    }

    private func removeOrphanedPayloads(keeping batches: [DraftBatch]) throws {
        let batchesByID = Dictionary(uniqueKeysWithValues: batches.map { ($0.id, $0) })
        let directories = try FileManager.default.contentsOfDirectory(
            at: payloadsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            guard let batchID = UUID(uuidString: directory.lastPathComponent),
                  let batch = batchesByID[batchID] else {
                try FileManager.default.removeItem(at: directory)
                continue
            }
            let documentsByID = Dictionary(uniqueKeysWithValues: batch.documents.map { ($0.id, $0) })
            let documentDirectories = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for documentDirectory in documentDirectories {
                guard let documentID = UUID(uuidString: documentDirectory.lastPathComponent),
                      let document = documentsByID[documentID] else {
                    try FileManager.default.removeItem(at: documentDirectory)
                    continue
                }
                let retainedFilenames = Set(document.pages.map(\.encryptedFilename))
                let payloadFiles = try FileManager.default.contentsOfDirectory(
                    at: documentDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for payloadFile in payloadFiles where !retainedFilenames.contains(payloadFile.lastPathComponent) {
                    try FileManager.default.removeItem(at: payloadFile)
                }
            }
        }
    }

    private func fileExtension(for contentType: String) -> String {
        UTType(contentType)?.preferredFilenameExtension ?? "bin"
    }

    private func writePDF(document: DraftDocument, batchID: UUID, destination: URL) throws {
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw OutputAssemblyError.couldNotCreateOutput
        }
        for page in document.pages {
            let materialized = try materializePage(batchID: batchID, documentID: document.id, page: page)
            defer { deleteMaterializedFile(materialized) }
            if UTType(page.originalContentType)?.conforms(to: .pdf) == true,
               let pdf = CGPDFDocument(materialized as CFURL), let pdfPage = pdf.page(at: 1) {
                let originalBox = pdfPage.getBoxRect(.mediaBox)
                let rotated = page.rotation == .clockwise90 || page.rotation == .counterClockwise90
                let pageWidth = rotated ? originalBox.height : originalBox.width
                let pageHeight = rotated ? originalBox.width : originalBox.height
                var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(pageInfo)
                if let preset = document.compressionPreset {
                    let image = try rasterizedImage(
                        pdfPage: pdfPage,
                        resolution: document.scanSettings.resolution,
                        preset: preset
                    )
                    let rotatedImage = try rotatedImage(image, rotation: page.rotation)
                    context.interpolationQuality = .high
                    context.draw(rotatedImage, in: mediaBox)
                } else {
                    let transform = pdfPage.getDrawingTransform(
                        .mediaBox,
                        rect: mediaBox,
                        rotate: Int32(page.rotation.rawValue),
                        preserveAspectRatio: true
                    )
                    context.concatenate(transform)
                    context.drawPDFPage(pdfPage)
                }
                context.endPDFPage()
                continue
            }
            guard let source = CGImageSourceCreateWithURL(materialized as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OutputAssemblyError.invalidPage
            }
            let originalWidth = max(page.physicalWidthPoints, 1)
            let originalHeight = max(page.physicalHeightPoints, 1)
            let rotated = page.rotation == .clockwise90 || page.rotation == .counterClockwise90
            let pageWidth = rotated ? originalHeight : originalWidth
            let pageHeight = rotated ? originalWidth : originalHeight
            var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            let outputImage = try document.compressionPreset.map { try compressedImage(image, preset: $0) } ?? image
            let rotatedImage = try rotatedImage(outputImage, rotation: page.rotation)
            context.interpolationQuality = .high
            context.draw(rotatedImage, in: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func writeJPEG(document: DraftDocument, batchID: UUID, destination: URL) throws {
        let page = document.pages[0]
        let materialized = try materializePage(batchID: batchID, documentID: document.id, page: page)
        defer { deleteMaterializedFile(materialized) }
        guard let source = CGImageSourceCreateWithURL(materialized as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OutputAssemblyError.invalidPage
        }
        let prepared = try document.compressionPreset.map { try compressedImage(original, preset: $0) } ?? original
        let image = try rotatedImage(prepared, rotation: page.rotation)
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw OutputAssemblyError.couldNotCreateOutput }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: document.compressionPreset?.imageQuality ?? 0.92,
            kCGImagePropertyDPIWidth: document.scanSettings.resolution,
            kCGImagePropertyDPIHeight: document.scanSettings.resolution
        ]
        CGImageDestinationAddImage(destinationRef, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw OutputAssemblyError.couldNotCreateOutput
        }
    }

    private func compressedImage(_ image: CGImage, preset: OutputCompressionPreset) throws -> CGImage {
        let width = max(Int(Double(image.width) * preset.dimensionScale), 1)
        let height = max(Int(Double(image.height) * preset.dimensionScale), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OutputAssemblyError.couldNotCreateOutput }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw OutputAssemblyError.couldNotCreateOutput }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw OutputAssemblyError.couldNotCreateOutput }
        CGImageDestinationAddImage(
            destination,
            resized,
            [kCGImageDestinationLossyCompressionQuality: preset.imageQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let result = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OutputAssemblyError.couldNotCreateOutput
        }
        return result
    }

    private func rasterizedImage(
        pdfPage: CGPDFPage,
        resolution: Int,
        preset: OutputCompressionPreset
    ) throws -> CGImage {
        let box = pdfPage.getBoxRect(.mediaBox)
        let scale = max(Double(resolution), 72) / 72
        let width = max(min(Int(box.width * scale), 10_000), 1)
        let height = max(min(Int(box.height * scale), 10_000), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OutputAssemblyError.couldNotCreateOutput }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(pdfPage.getDrawingTransform(.mediaBox, rect: destination, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdfPage)
        guard let image = context.makeImage() else { throw OutputAssemblyError.couldNotCreateOutput }
        return try compressedImage(image, preset: preset)
    }

    private func draw(
        _ image: CGImage,
        rotation: PageRotation,
        originalWidth: Double,
        originalHeight: Double,
        in context: CGContext,
        pageWidth: Double,
        pageHeight: Double
    ) {
        context.saveGState()
        context.translateBy(x: 0, y: pageHeight)
        context.scaleBy(x: 1, y: -1)
        switch rotation {
        case .zero: break
        case .clockwise90:
            context.translateBy(x: pageWidth, y: 0)
            context.rotate(by: .pi / 2)
        case .upsideDown:
            context.translateBy(x: pageWidth, y: pageHeight)
            context.rotate(by: .pi)
        case .counterClockwise90:
            context.translateBy(x: 0, y: pageHeight)
            context.rotate(by: -.pi / 2)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
        context.restoreGState()
    }

    private func rotatedImage(_ image: CGImage, rotation: PageRotation) throws -> CGImage {
        guard rotation != .zero else { return image }
        let swapped = rotation == .clockwise90 || rotation == .counterClockwise90
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OutputAssemblyError.couldNotCreateOutput }
        draw(
            image,
            rotation: rotation,
            originalWidth: Double(image.width),
            originalHeight: Double(image.height),
            in: context,
            pageWidth: Double(width),
            pageHeight: Double(height)
        )
        guard let result = context.makeImage() else { throw OutputAssemblyError.couldNotCreateOutput }
        return result
    }

    private func uniqueFilename(
        for document: DraftDocument,
        batch: DraftBatch,
        index: Int,
        pattern: String?,
        used: inout Set<String>
    ) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        var rendered = pattern?.isEmpty == false ? pattern! : document.name
        rendered = rendered
            .replacingOccurrences(of: "{document_id}", with: document.id.uuidString)
            .replacingOccurrences(of: "{batch_id}", with: batch.logicalBatchID.uuidString)
            .replacingOccurrences(of: "{index}", with: String(index + 1))
            .replacingOccurrences(of: "{name}", with: document.name)
            .replacingOccurrences(of: "{date}", with: Self.filenameDateFormatter.string(from: document.createdAt))
        let base = rendered.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) }
        var normalized = String(base).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { normalized = "document" }
        normalized = String(normalized.prefix(180))
        var candidate = "\(normalized).\(document.outputFormat.fileExtension)"
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            candidate = "\(String(normalized.prefix(170)))-\(suffix).\(document.outputFormat.fileExtension)"
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static let documentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum OutputAssemblyError: LocalizedError {
    case couldNotCreateOutput
    case invalidPage
    case jpegRequiresSinglePage

    var errorDescription: String? {
        switch self {
        case .couldNotCreateOutput: String(localized: "The output file could not be created.")
        case .invalidPage: String(localized: "A retained page could not be decoded. The draft remains safe.")
        case .jpegRequiresSinglePage: String(localized: "JPEG output supports exactly one page.")
        }
    }
}
