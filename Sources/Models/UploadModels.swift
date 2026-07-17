import Foundation

struct PreparedDocument: Identifiable, Equatable, Sendable {
    var id: UUID
    var fileURL: URL
    var filename: String
    var contentType: String
    var byteCount: Int64
    var pageCount: Int
}

enum DocumentUploadActivity: Equatable, Sendable {
    case queued
    case uploading(Double)
    case waitingToRetry(attempt: Int, seconds: Int)
    case confirmed
    case unconfirmed(String?)
    case failed(String)
}

enum UploadActivity: Equatable, Sendable {
    case idle
    case preparing
    case uploading(progress: Double)
    case waitingToRetry(attempt: Int, seconds: Int)
    case waitingForNetwork
    case completed(String)
    case failed(String)
    case cancelled

    var isBusy: Bool {
        switch self {
        case .preparing, .uploading, .waitingToRetry, .waitingForNetwork: true
        default: false
        }
    }
}

struct UploadDocumentResult: Equatable, Sendable {
    var documentID: UUID
    var confirmation: InterpretedResponse.Confirmation
    var requestID: UUID?
    var statusCode: Int?
    var message: String?
    var remoteID: String?
    var openURL: URL?
    var attemptCount: Int = 1
}

struct UploadAttemptEvent: Equatable, Sendable {
    var requestID: UUID
    var documentIDs: [UUID]
    var attemptNumber: Int
    var attemptedAt: Date
    var statusCode: Int?
    var outcome: String
}

struct LongRetryPrompt: Identifiable, Equatable, Sendable {
    var id: UUID
    var seconds: Int
}

struct UploadBatchResult: Equatable, Sendable {
    var documentResults: [UploadDocumentResult]
    var message: String?
}
