import Foundation

enum TransferHistoryResult: String, Codable, Sendable {
    case sent
    case partiallySent
    case failed
    case unconfirmed
}

struct TransferHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var destinationName: String
    var destinationHost: String
    var documentCount: Int
    var pageCount: Int
    var result: TransferHistoryResult
    var remoteIDs: [String]
    var batchID: UUID
    var documentIDs: [UUID]
    var requestIDs: [UUID]
    var errorCategory: String?
    var openURL: URL?
}
