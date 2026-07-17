import Foundation

enum DiskCapacityGuard {
    static let reservedHeadroom: Int64 = 500_000_000

    static func verify(availableBytes: Int64?, requiredBytes: Int64) throws {
        let required = max(requiredBytes, 0)
        guard required <= Int64.max - reservedHeadroom else {
            throw DraftStoreError.insufficientDiskSpace
        }
        if let availableBytes, availableBytes < required + reservedHeadroom {
            throw DraftStoreError.insufficientDiskSpace
        }
    }

    static func availableCapacity(at url: URL) throws -> Int64? {
        try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func verify(at url: URL, requiredBytes: Int64) throws {
        try verify(availableBytes: availableCapacity(at: url), requiredBytes: requiredBytes)
    }
}
