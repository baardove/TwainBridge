import Foundation

enum ScanSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case flatbed
    case documentFeeder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .flatbed: String(localized: "Flatbed")
        case .documentFeeder: String(localized: "Document Feeder")
        }
    }

    var symbolName: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .flatbed: "scanner"
        case .documentFeeder: "doc.on.doc"
        }
    }
}

enum ScanColorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case color
    case grayscale
    case blackAndWhite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: String(localized: "Color")
        case .grayscale: String(localized: "Grayscale")
        case .blackAndWhite: String(localized: "Black & White")
        }
    }
}

enum ScanPageSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case a4
    case a5
    case usLetter
    case usLegal
    case businessCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic / Full Area")
        case .a4: String(localized: "A4")
        case .a5: String(localized: "A5")
        case .usLetter: String(localized: "US Letter")
        case .usLegal: String(localized: "US Legal")
        case .businessCard: String(localized: "Business Card")
        }
    }

    /// Raw values from ICScannerDocumentType. Kept framework-independent so the
    /// persisted request model stays usable in tests and future acquisition backends.
    var imageCaptureDocumentTypeRawValue: Int? {
        switch self {
        case .automatic: nil
        case .a4: 1
        case .usLetter: 3
        case .usLegal: 4
        case .a5: 5
        case .businessCard: 53
        }
    }

    static func imageCapturePageSize(rawValue: Int) -> ScanPageSize? {
        allCases.first { $0.imageCaptureDocumentTypeRawValue == rawValue }
    }
}

enum ScanOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case portrait
    case landscape

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .portrait: String(localized: "Portrait")
        case .landscape: String(localized: "Landscape")
        }
    }
}

enum ScannerConnection: String, Codable, Sendable {
    case usb = "USB"
    case network = "Network"
    case shared = "Shared"
    case unknown = "Unknown"
}

struct ScannerCapabilities: Equatable, Sendable {
    var availableSources: Set<ScanSource>
    var resolutions: [Int]
    var pageSizes: [ScanPageSize] = [.automatic]
    var supportsDuplex: Bool
    var feederDocumentLoaded: Bool?

    static let unavailable = ScannerCapabilities(
        availableSources: [],
        resolutions: [150, 200, 300, 600],
        pageSizes: [.automatic],
        supportsDuplex: false,
        feederDocumentLoaded: nil
    )

    var sourceChoices: [ScanSource] {
        var choices: [ScanSource] = []
        if availableSources.count > 1 {
            choices.append(.automatic)
        }
        if availableSources.contains(.flatbed) {
            choices.append(.flatbed)
        }
        if availableSources.contains(.documentFeeder) {
            choices.append(.documentFeeder)
        }
        return choices
    }

    func resolvedSource(for requestedSource: ScanSource) -> ScanSource? {
        switch requestedSource {
        case .flatbed:
            return availableSources.contains(.flatbed) ? .flatbed : nil
        case .documentFeeder:
            return availableSources.contains(.documentFeeder) ? .documentFeeder : nil
        case .automatic:
            if availableSources.contains(.documentFeeder), feederDocumentLoaded == true {
                return .documentFeeder
            }
            if availableSources.contains(.flatbed) {
                return .flatbed
            }
            if availableSources.contains(.documentFeeder) {
                return .documentFeeder
            }
            return nil
        }
    }
}

struct ScannerSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var connection: ScannerConnection
    var location: String
    var capabilities: ScannerCapabilities
}

struct ScanRequest: Codable, Equatable, Sendable {
    var scannerID: String
    var source: ScanSource
    var colorMode: ScanColorMode
    var resolution: Int
    var duplex: Bool
    var pageSize: ScanPageSize
    var orientation: ScanOrientation

    init(
        scannerID: String,
        source: ScanSource,
        colorMode: ScanColorMode,
        resolution: Int,
        duplex: Bool,
        pageSize: ScanPageSize = .automatic,
        orientation: ScanOrientation = .automatic
    ) {
        self.scannerID = scannerID
        self.source = source
        self.colorMode = colorMode
        self.resolution = resolution
        self.duplex = duplex
        self.pageSize = pageSize
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey {
        case scannerID, source, colorMode, resolution, duplex, pageSize, orientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scannerID = try container.decode(String.self, forKey: .scannerID)
        source = try container.decode(ScanSource.self, forKey: .source)
        colorMode = try container.decode(ScanColorMode.self, forKey: .colorMode)
        resolution = try container.decode(Int.self, forKey: .resolution)
        duplex = try container.decode(Bool.self, forKey: .duplex)
        pageSize = try container.decodeIfPresent(ScanPageSize.self, forKey: .pageSize) ?? .automatic
        orientation = try container.decodeIfPresent(ScanOrientation.self, forKey: .orientation) ?? .automatic
    }
}

struct CompletedScanResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let pageURLs: [URL]
    let request: ScanRequest
    let scannerName: String
    let completedAt: Date
    let interrupted: Bool
}

enum ScannerFailureCategory: String, Codable, Equatable, Sendable {
    case paperJam
    case doubleFeed
    case feederEmpty
    case coverOpen
    case busy
    case disconnected
    case permissionDenied
    case unsupportedSetting
    case cancelled
    case storage
    case unknown
}

struct ScannerFailure: Equatable, Sendable {
    var category: ScannerFailureCategory
    var headline: String
    var recoverySuggestion: String
    var technicalCode: String?

    var displayMessage: String {
        recoverySuggestion.isEmpty ? headline : "\(headline) \(recoverySuggestion)"
    }

    static func disconnected() -> ScannerFailure {
        ScannerFailure(
            category: .disconnected,
            headline: String(localized: "The scanner disconnected."),
            recoverySuggestion: String(localized: "Reconnect it, then continue scanning; pages already captured remain safe."),
            technicalCode: nil
        )
    }

    static func unsupportedSetting(_ headline: String) -> ScannerFailure {
        ScannerFailure(
            category: .unsupportedSetting,
            headline: headline,
            recoverySuggestion: String(localized: "Choose a setting reported by the selected source and try again."),
            technicalCode: nil
        )
    }

    static func storage(pagesAlreadyScanned: Bool = false) -> ScannerFailure {
        ScannerFailure(
            category: .storage,
            headline: pagesAlreadyScanned
                ? String(localized: "The pages were scanned but could not be secured locally.")
                : String(localized: "TwainBridge could not prepare secure local storage."),
            recoverySuggestion: String(localized: "Free disk space and check folder permissions before trying again."),
            technicalCode: nil
        )
    }

    static func unknown() -> ScannerFailure {
        ScannerFailure(
            category: .unknown,
            headline: String(localized: "The scanner could not complete the scan."),
            recoverySuggestion: String(localized: "Check the scanner display and paper path, then try again."),
            technicalCode: nil
        )
    }

    static func classify(_ error: Error) -> ScannerFailure {
        let nsError = error as NSError
        let technicalCode = "\(nsError.domain)(\(nsError.code))"
        let text = [
            nsError.localizedDescription,
            nsError.localizedFailureReason,
            nsError.localizedRecoverySuggestion
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        func result(
            _ category: ScannerFailureCategory,
            _ headline: String,
            _ suggestion: String
        ) -> ScannerFailure {
            ScannerFailure(
                category: category,
                headline: headline,
                recoverySuggestion: suggestion,
                technicalCode: technicalCode
            )
        }

        // Stable ImageCaptureCore return codes are handled before vendor text.
        switch nsError.code {
        case -9924:
            return result(.cancelled, String(localized: "Scanning was cancelled."), String(localized: "Pages already captured remain available to keep or continue."))
        case -9925, -9926, -9954:
            return result(.busy, String(localized: "The scanner is in use."), String(localized: "Wait for the other scan to finish, then try again."))
        case -21350, -21349, -21348, -21345, -21344, -9923:
            return result(.disconnected, String(localized: "Communication with the scanner was lost."), String(localized: "Check its power and connection, then continue scanning."))
        case -21343, -21249:
            return result(.permissionDenied, String(localized: "macOS did not authorize scanner access."), String(localized: "Review Privacy & Security and the scanner’s network credentials."))
        case -9922, -9929:
            return result(.unsupportedSetting, String(localized: "The scanner rejected a selected setting."), String(localized: "Choose another source, page size, or resolution and try again."))
        default:
            break
        }

        if text.contains("double feed") || text.contains("double-feed") || text.contains("multifeed") {
            return result(.doubleFeed, String(localized: "The feeder detected more than one sheet."), String(localized: "Separate and fan the pages, then continue scanning."))
        }
        if text.contains("paper jam") || text.contains("jammed") || text.contains("paper jam") {
            return result(.paperJam, String(localized: "Paper is jammed in the scanner."), String(localized: "Clear the paper path, reload the remaining pages, then continue."))
        }
        if text.contains("no document") || text.contains("feeder empty") || text.contains("out of paper") {
            return result(.feederEmpty, String(localized: "The document feeder is empty."), String(localized: "Load the remaining pages, then continue scanning."))
        }
        if text.contains("cover open") || text.contains("door open") {
            return result(.coverOpen, String(localized: "The scanner cover is open."), String(localized: "Close it securely, then continue scanning."))
        }
        if text.contains("busy") || text.contains("in use") {
            return result(.busy, String(localized: "The scanner is in use."), String(localized: "Wait for it to become ready, then try again."))
        }
        if text.contains("not authorized") || text.contains("permission") || text.contains("access denied") {
            return result(.permissionDenied, String(localized: "Scanner access was denied."), String(localized: "Review Privacy & Security and the scanner’s network credentials."))
        }
        if text.contains("offline") || text.contains("disconnect") || text.contains("communication") || text.contains("network") {
            return result(.disconnected, String(localized: "Communication with the scanner was lost."), String(localized: "Check its power and connection, then continue scanning."))
        }
        return ScannerFailure(
            category: .unknown,
            headline: String(localized: "The scanner could not complete the scan."),
            recoverySuggestion: String(localized: "Check the scanner display and paper path, then try again."),
            technicalCode: technicalCode
        )
    }
}

enum ScannerActivity: Equatable, Sendable {
    case discovering
    case ready
    case openingSession
    case selectingSource
    case scanning(progress: Double)
    case completed(pageCount: Int)
    case unavailable(String)
    case failed(ScannerFailure)

    var label: String {
        switch self {
        case .discovering: String(localized: "Looking for scanners…")
        case .ready: String(localized: "Ready")
        case .openingSession: String(localized: "Opening scanner…")
        case .selectingSource: String(localized: "Preparing source…")
        case let .scanning(progress):
            progress > 0
                ? String(localized: "Scanning… \(Int(progress.rounded())) pages captured")
                : String(localized: "Scanning…")
        case let .completed(pageCount): String(localized: "\(pageCount) pages scanned")
        case let .unavailable(message): message
        case let .failed(failure): failure.displayMessage
        }
    }

    var isBusy: Bool {
        switch self {
        case .openingSession, .selectingSource, .scanning: true
        default: false
        }
    }
}
