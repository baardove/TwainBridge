import Foundation

enum DraftState: String, Codable, CaseIterable, Sendable {
    case acquiring
    case interrupted
    case ready
    case needsInformation
    case preparing
    case uploading
    case waitingForNetwork
    case partiallySent
    case failed
    case sent

    var title: String {
        switch self {
        case .acquiring: String(localized: "Acquiring")
        case .interrupted: String(localized: "Interrupted")
        case .ready: String(localized: "Ready")
        case .needsInformation: String(localized: "Needs Information")
        case .preparing: String(localized: "Preparing")
        case .uploading: String(localized: "Uploading")
        case .waitingForNetwork: String(localized: "Waiting for Network")
        case .partiallySent: String(localized: "Partially Sent")
        case .failed: String(localized: "Failed")
        case .sent: String(localized: "Sent")
        }
    }
}

enum DocumentOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf
    case jpeg

    var id: String { rawValue }
    var title: String { self == .pdf ? String(localized: "PDF") : String(localized: "JPEG") }
    var fileExtension: String { self == .pdf ? "pdf" : "jpg" }
    var contentType: String { self == .pdf ? "application/pdf" : "image/jpeg" }
}

enum OutputCompressionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced
    case smaller

    var id: String { rawValue }
    var title: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .smaller: String(localized: "Smaller File")
        }
    }
    var detail: String {
        switch self {
        case .balanced: String(localized: "About 80% dimensions, 72% image quality")
        case .smaller: String(localized: "About 60% dimensions, 55% image quality")
        }
    }
    var dimensionScale: Double { self == .balanced ? 0.8 : 0.6 }
    var imageQuality: Double { self == .balanced ? 0.72 : 0.55 }
    var estimatedSizeRatio: Double { self == .balanced ? 0.55 : 0.3 }
}

enum PageRotation: Int, Codable, CaseIterable, Sendable {
    case zero = 0
    case clockwise90 = 90
    case upsideDown = 180
    case counterClockwise90 = 270

    func rotatedClockwise() -> PageRotation {
        PageRotation(rawValue: (rawValue + 90) % 360) ?? .zero
    }

    func rotatedCounterClockwise() -> PageRotation {
        PageRotation(rawValue: (rawValue + 270) % 360) ?? .zero
    }
}

struct ScanSettingsSnapshot: Codable, Equatable, Sendable {
    var scannerID: String
    var scannerName: String
    var source: ScanSource
    var colorMode: ScanColorMode
    var resolution: Int
    var duplex: Bool
    var pageSize: ScanPageSize = .automatic
    var orientation: ScanOrientation = .automatic

    private enum CodingKeys: String, CodingKey {
        case scannerID, scannerName, source, colorMode, resolution, duplex, pageSize, orientation
    }

    init(
        scannerID: String,
        scannerName: String,
        source: ScanSource,
        colorMode: ScanColorMode,
        resolution: Int,
        duplex: Bool,
        pageSize: ScanPageSize = .automatic,
        orientation: ScanOrientation = .automatic
    ) {
        self.scannerID = scannerID
        self.scannerName = scannerName
        self.source = source
        self.colorMode = colorMode
        self.resolution = resolution
        self.duplex = duplex
        self.pageSize = pageSize
        self.orientation = orientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scannerID = try container.decode(String.self, forKey: .scannerID)
        scannerName = try container.decode(String.self, forKey: .scannerName)
        source = try container.decode(ScanSource.self, forKey: .source)
        colorMode = try container.decode(ScanColorMode.self, forKey: .colorMode)
        resolution = try container.decode(Int.self, forKey: .resolution)
        duplex = try container.decode(Bool.self, forKey: .duplex)
        pageSize = try container.decodeIfPresent(ScanPageSize.self, forKey: .pageSize) ?? .automatic
        orientation = try container.decodeIfPresent(ScanOrientation.self, forKey: .orientation) ?? .automatic
    }
}

struct DraftPage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var encryptedFilename: String
    var originalContentType: String
    var pixelWidth: Int
    var pixelHeight: Int
    var physicalWidthPoints: Double
    var physicalHeightPoints: Double
    var rotation: PageRotation
    var originalByteCount: Int64
    var createdAt: Date
    var scanSettings: ScanSettingsSnapshot? = nil
}

enum DraftInsertionTarget: Equatable, Sendable {
    case newBatch
    case appendPages(batchID: UUID, documentID: UUID)
    case newDocument(batchID: UUID)
    case replaceDocument(batchID: UUID, documentID: UUID)
}

struct UploadAttemptRecord: Codable, Equatable, Sendable {
    var requestID: UUID
    var attemptedAt: Date
    var statusCode: Int?
    var outcome: String
}

struct DocumentTransferState: Codable, Equatable, Sendable {
    var confirmed: Bool = false
    var remoteID: String?
    var openURL: URL?
    var lastRequestID: UUID?
    var attemptCount: Int = 0
    var lastStatusCode: Int?
    var lastAttemptAt: Date?
    var sanitizedError: String?
    var attempts: [UploadAttemptRecord] = []

    private enum CodingKeys: String, CodingKey {
        case confirmed, remoteID, openURL, lastRequestID, attemptCount, lastStatusCode
        case lastAttemptAt, sanitizedError, attempts
    }

    init(
        confirmed: Bool = false,
        remoteID: String? = nil,
        openURL: URL? = nil,
        lastRequestID: UUID? = nil,
        attemptCount: Int = 0,
        lastStatusCode: Int? = nil,
        lastAttemptAt: Date? = nil,
        sanitizedError: String? = nil,
        attempts: [UploadAttemptRecord] = []
    ) {
        self.confirmed = confirmed
        self.remoteID = remoteID
        self.openURL = openURL
        self.lastRequestID = lastRequestID
        self.attemptCount = attemptCount
        self.lastStatusCode = lastStatusCode
        self.lastAttemptAt = lastAttemptAt
        self.sanitizedError = sanitizedError
        self.attempts = attempts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        remoteID = try container.decodeIfPresent(String.self, forKey: .remoteID)
        openURL = try container.decodeIfPresent(URL.self, forKey: .openURL)
        lastRequestID = try container.decodeIfPresent(UUID.self, forKey: .lastRequestID)
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastStatusCode = try container.decodeIfPresent(Int.self, forKey: .lastStatusCode)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        sanitizedError = try container.decodeIfPresent(String.self, forKey: .sanitizedError)
        attempts = try container.decodeIfPresent([UploadAttemptRecord].self, forKey: .attempts) ?? []
    }
}

struct DraftDocument: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var pages: [DraftPage]
    var scanSettings: ScanSettingsSnapshot
    var outputFormat: DocumentOutputFormat
    /// Optional so version-1 manifests written before compression support remain decodable.
    var compressionPreset: OutputCompressionPreset?
    var metadata: [String: String]
    var transfer: DocumentTransferState
    var createdAt: Date
    var updatedAt: Date
}

struct DraftBatch: Identifiable, Codable, Equatable, Sendable {
    static let manifestVersion = 1

    var version: Int = manifestVersion
    var id: UUID
    /// Remote logical identifier. The storage ID remains stable while this ID
    /// can be rotated when a draft is intentionally sent to a different host.
    var logicalBatchID: UUID
    var documents: [DraftDocument]
    var destinationID: UUID?
    var state: DraftState
    var createdAt: Date
    var updatedAt: Date
    var lastErrorCategory: String?
    var metadata: [String: String] = [:]
    /// When true, encrypted payloads are retained as part of the local document library.
    /// This is independent of the metadata-only transfer history.
    var isStoredInLibrary: Bool = true

    var pageCount: Int { documents.reduce(0) { $0 + $1.pages.count } }
    var actionableDocumentCount: Int { documents.filter { !$0.transfer.confirmed }.count }

    init(
        version: Int = manifestVersion,
        id: UUID,
        logicalBatchID: UUID? = nil,
        documents: [DraftDocument],
        destinationID: UUID?,
        state: DraftState,
        createdAt: Date,
        updatedAt: Date,
        lastErrorCategory: String?,
        metadata: [String: String] = [:],
        isStoredInLibrary: Bool = true
    ) {
        self.version = version
        self.id = id
        self.logicalBatchID = logicalBatchID ?? id
        self.documents = documents
        self.destinationID = destinationID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastErrorCategory = lastErrorCategory
        self.metadata = metadata
        self.isStoredInLibrary = isStoredInLibrary
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, logicalBatchID, documents, destinationID, state, createdAt, updatedAt, lastErrorCategory, metadata, isStoredInLibrary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        logicalBatchID = try container.decodeIfPresent(UUID.self, forKey: .logicalBatchID) ?? id
        documents = try container.decode([DraftDocument].self, forKey: .documents)
        destinationID = try container.decodeIfPresent(UUID.self, forKey: .destinationID)
        state = try container.decode(DraftState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastErrorCategory = try container.decodeIfPresent(String.self, forKey: .lastErrorCategory)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        // Existing encrypted drafts become library items on upgrade so previously
        // captured content is not silently removed by retention cleanup.
        isStoredInLibrary = try container.decodeIfPresent(Bool.self, forKey: .isStoredInLibrary) ?? true
    }
}

enum DocumentCaptureOrigin: String, CaseIterable, Identifiable, Hashable, Sendable {
    case scanner
    case webcam
    case watchedFolder
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scanner: String(localized: "Scanner")
        case .webcam: String(localized: "Webcam")
        case .watchedFolder: String(localized: "Watched Folder")
        case .mixed: String(localized: "Mixed Sources")
        }
    }

    var symbolName: String {
        switch self {
        case .scanner: "scanner"
        case .webcam: "camera"
        case .watchedFolder: "folder"
        case .mixed: "square.stack.3d.up"
        }
    }
}

extension DraftBatch {
    var captureOrigin: DocumentCaptureOrigin {
        let origins = Set(documents.map { document -> DocumentCaptureOrigin in
            let scannerID = document.scanSettings.scannerID.lowercased()
            if scannerID.hasPrefix("webcam:") { return .webcam }
            if scannerID == "watched-folder" { return .watchedFolder }
            return .scanner
        })
        return origins.count == 1 ? (origins.first ?? .scanner) : .mixed
    }

    var originalByteCount: Int64 {
        documents.flatMap(\.pages).reduce(0) { $0 + max($1.originalByteCount, 0) }
    }
}

enum DraftStoreError: LocalizedError, Equatable {
    case initializationFailed(String)
    case draftLimitReached
    case insufficientDiskSpace
    case draftNotFound
    case documentNotFound
    case pageNotFound
    case confirmedDocumentReadOnly
    case corruptPayload
    case unsupportedManifestVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .initializationFailed(message): String(localized: "Draft storage could not start: \(message)")
        case .draftLimitReached: String(localized: "The 20-draft limit has been reached. Send, save, or discard a draft before scanning again.")
        case .insufficientDiskSpace: String(localized: "There is not enough free disk space to preserve this scan safely.")
        case .draftNotFound: String(localized: "The draft could not be found.")
        case .documentNotFound: String(localized: "The document could not be found.")
        case .pageNotFound: String(localized: "The page could not be found.")
        case .confirmedDocumentReadOnly: String(localized: "This document was already confirmed by the receiver and is read-only. Create a new copy before changing it.")
        case .corruptPayload: String(localized: "The encrypted page could not be verified or opened.")
        case let .unsupportedManifestVersion(version): String(localized: "Draft manifest version \(version) is not supported.")
        }
    }
}
