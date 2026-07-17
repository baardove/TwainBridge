import Foundation

enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case post = "POST"
    case put = "PUT"
    var id: String { rawValue }
}

enum AuthenticationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bearerToken
    case customHeader
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .bearerToken: String(localized: "Bearer Token")
        case .customHeader: String(localized: "Custom Header")
        }
    }
}

struct AuthenticationConfiguration: Codable, Equatable, Sendable {
    var kind: AuthenticationKind = .none
    var headerName: String = "Authorization"
}

enum PagePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case singlePage
    case multiplePages
    var id: String { rawValue }
}

enum SinglePageOverflowBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case startNewDocument
    case ask
    case reject
    var id: String { rawValue }
}

enum AdditionalPageDecision: Equatable, Sendable {
    case appendToCurrentDocument
    case startNewDocument
    case askToStartNewDocument
    case rejectSinglePage
    case maximumPagesReached(Int)
}

enum BatchPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneDocument
    case multipleDocuments
    var id: String { rawValue }
}

enum BatchRequestMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneMultipartRequest
    case oneRequestPerDocument
    var id: String { rawValue }
}

enum PartialSuccessBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepFailedOnly
    case keepCompleteBatch
    var id: String { rawValue }
}

enum FileFieldConvention: String, Codable, CaseIterable, Identifiable, Sendable {
    case repeated
    case indexed
    case customPerDocument
    var id: String { rawValue }
}

enum RequestConcurrency: String, Codable, CaseIterable, Identifiable, Sendable {
    case sequential
    case twoAtATime
    var id: String { rawValue }
}

enum ParameterLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case header
    case form
    case query
    var id: String { rawValue }
}

enum ParameterValueSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed
    case builtIn
    case generated
    case userEntered
    var id: String { rawValue }
}

enum ParameterScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case request
    case batch
    case document
    var id: String { rawValue }
}

enum ParameterDataType: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case integer
    case decimal
    case boolean
    case date
    case dateTime
    case choice
    var id: String { rawValue }
}

enum BuiltInParameterValue: String, Codable, CaseIterable, Identifiable, Sendable {
    case documentID = "document_id"
    case batchID = "batch_id"
    case filename
    case pageCount = "page_count"
    case documentCount = "document_count"
    case scannedAt = "scanned_at"
    case scannerName = "scanner_name"
    case contentType = "content_type"
    case requestID = "request_id"
    var id: String { rawValue }
}

struct DestinationParameter: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var enabled = true
    var name = ""
    var location: ParameterLocation = .form
    var valueSource: ParameterValueSource = .fixed
    var scope: ParameterScope = .request
    var dataType: ParameterDataType = .text
    var value: String?
    var builtInValue: BuiltInParameterValue?
    var required = false
    var sensitive = false
    var label: String?
    var helpText: String?
    var defaultValue: String?
    var allowedValues: [String] = []
    var minimum: Double?
    var maximum: Double?
    var maximumLength: Int?
    var validationExpression: String?
    var rememberValue = true

    func sanitizedForPersistence() -> DestinationParameter {
        var copy = self
        if sensitive { copy.value = nil; copy.defaultValue = nil }
        return copy
    }
}

struct ParameterValueKey: Hashable, Sendable {
    var parameterID: UUID
    var documentID: UUID?
}

enum ResponseMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standardJSON
    case statusOnly
    case customJSON
    var id: String { rawValue }
}

struct HTTPStatusRange: Codable, Equatable, Sendable {
    var lowerBound: Int = 200
    var upperBound: Int = 299
    func contains(_ status: Int) -> Bool { lowerBound...upperBound ~= status }
}

struct CustomResponseMapping: Codable, Equatable, Sendable {
    var successPath = "success"
    var messagePath = "message"
    var remoteIDPath = "id"
    var openURLPath = "open_url"
    var documentsPath = "documents"
    var documentIdentifierPath = "document_id"
}

struct ResponseConfiguration: Codable, Equatable, Sendable {
    var mode: ResponseMode = .standardJSON
    var successStatuses = HTTPStatusRange()
    var permitsEmptyBody = false
    var expectedContentType = "application/json"
    var maximumBodyBytes = 1_048_576
    var missingOptionalFieldsAllowed = true
    var custom = CustomResponseMapping()
}

struct DestinationProfile: Identifiable, Codable, Equatable, Sendable {
    static let profileVersion = 1

    var version = profileVersion
    var id: UUID = UUID()
    var displayName = "New Destination"
    var endpointURL = ""
    var method: HTTPMethod = .post
    var fileFieldName = "file"
    var filenamePattern = "document-{document_id}"
    var pagePolicy: PagePolicy = .multiplePages
    var singlePageOverflow: SinglePageOverflowBehavior = .startNewDocument
    var maximumPagesPerDocument: Int?
    var batchPolicy: BatchPolicy = .oneDocument
    var maximumDocumentsPerBatch = 20
    var batchRequestMode: BatchRequestMode = .oneMultipartRequest
    var partialSuccessBehavior: PartialSuccessBehavior = .keepFailedOnly
    var fileFieldConvention: FileFieldConvention = .repeated
    // Optional so destination profiles created before custom file-field patterns
    // continue to decode without a migration.
    var customFileFieldPattern: String?
    var includeBatchManifest = true
    var manifestFieldName = "manifest"
    var documentOrderSignificant = true
    var requestConcurrency: RequestConcurrency = .sequential
    var acceptedOutputFormats: Set<DocumentOutputFormat> = [.pdf]
    var maximumFileBytes: Int64?
    var maximumBatchBytes: Int64?
    var requestTimeout: Double = 60
    var authentication = AuthenticationConfiguration()
    var parameters: [DestinationParameter] = []
    var response = ResponseConfiguration()
    var receiverSupportsIdempotency = true
    var idempotencyHeaderName = "Idempotency-Key"
    var openBrowserAfterSend = false
    var allowedRedirectHosts: [String] = []
    var enabled = true
    var lastConnectionTestAt: Date?
    var lastConnectionTestSucceeded = false

    var host: String? { URL(string: endpointURL)?.host?.lowercased() }

    func sanitizedForPersistence() -> DestinationProfile {
        var copy = self
        copy.parameters = parameters.map { $0.sanitizedForPersistence() }
        return copy
    }

    func exportedCopy() -> DestinationProfile {
        var copy = sanitizedForPersistence()
        copy.lastConnectionTestAt = nil
        copy.lastConnectionTestSucceeded = false
        copy.enabled = authentication.kind == .none && !parameters.contains(where: { $0.sensitive })
        return copy
    }

    func additionalPageDecision(currentPageCount: Int) -> AdditionalPageDecision {
        if let maximumPagesPerDocument, currentPageCount >= maximumPagesPerDocument {
            return .maximumPagesReached(maximumPagesPerDocument)
        }
        guard pagePolicy == .singlePage, currentPageCount >= 1 else {
            return .appendToCurrentDocument
        }
        return switch singlePageOverflow {
        case .startNewDocument: .startNewDocument
        case .ask: .askToStartNewDocument
        case .reject: .rejectSinglePage
        }
    }

    func projectedOutboundDocumentCount(pageCounts: [Int]) -> Int {
        guard pagePolicy == .singlePage, singlePageOverflow != .reject else {
            return pageCounts.count
        }
        return pageCounts.reduce(0) { $0 + max($1, 1) }
    }
}

struct DestinationCollection: Codable, Equatable, Sendable {
    var version = 1
    var defaultDestinationID: UUID?
    var lastSelectedDestinationID: UUID?
    var profiles: [DestinationProfile] = []
}

enum DestinationValidationSeverity: String, Sendable {
    case warning
    case error
}

struct DestinationValidationIssue: Identifiable, Equatable, Sendable {
    let id: String
    let severity: DestinationValidationSeverity
    let message: String
}

struct ConnectionTestResult: Equatable, Sendable {
    enum Outcome: String, Sendable {
        case success
        case authenticationFailure
        case invalidResponse
        case tlsFailure
        case serverFailure
        case unreachable
    }

    var outcome: Outcome
    var statusCode: Int?
    var summary: String
    var succeeded: Bool { outcome == .success }
}
