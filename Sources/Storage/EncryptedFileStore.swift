import CryptoKit
import Foundation

enum EncryptedFileStoreError: LocalizedError {
    case invalidHeader
    case invalidRecord
    case truncatedFile
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidHeader: String(localized: "The encrypted page header is invalid.")
        case .invalidRecord: String(localized: "The encrypted page contains an invalid record.")
        case .truncatedFile: String(localized: "The encrypted page is incomplete.")
        case .authenticationFailed: String(localized: "The encrypted page failed authentication.")
        }
    }
}

/// A bounded-memory authenticated file container.
///
/// Each 1 MiB chunk is independently sealed with AES-GCM and authenticated with
/// its sequence number. An authenticated footer binds the number of chunks and
/// total plaintext length, preventing reordering or silent truncation.
enum EncryptedFileStore {
    private static let magic = Data("TBP1".utf8)
    private static let chunkSize = 1_048_576
    private static let maximumRecordSize = chunkSize + 64

    static func encrypt(source: URL, destination: URL, keyData: Data) throws {
        let key = SymmetricKey(data: keyData)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? input.close()
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        try output.write(contentsOf: magic)
        try output.write(contentsOf: encode(UInt32(chunkSize)))

        var index: UInt64 = 0
        var totalPlaintextBytes: UInt64 = 0
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            let sealed = try AES.GCM.seal(chunk, using: key, authenticating: chunkAAD(index: index))
            guard let combined = sealed.combined else { throw EncryptedFileStoreError.authenticationFailed }
            try output.write(contentsOf: encode(UInt32(combined.count)))
            try output.write(contentsOf: combined)
            index += 1
            totalPlaintextBytes += UInt64(chunk.count)
        }

        try output.write(contentsOf: encode(UInt32(0)))
        let footerValues = encode(index) + encode(totalPlaintextBytes)
        let footer = try AES.GCM.seal(Data(), using: key, authenticating: footerAAD(values: footerValues))
        guard let footerCombined = footer.combined else { throw EncryptedFileStoreError.authenticationFailed }
        try output.write(contentsOf: footerValues)
        try output.write(contentsOf: encode(UInt32(footerCombined.count)))
        try output.write(contentsOf: footerCombined)
        try output.synchronize()
        succeeded = true
    }

    static func decrypt(source: URL, destination: URL, keyData: Data) throws {
        let key = SymmetricKey(data: keyData)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? input.close()
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        guard try readExact(from: input, count: magic.count) == magic else {
            throw EncryptedFileStoreError.invalidHeader
        }
        let storedChunkSize = try decodeUInt32(readRequired(from: input, count: 4))
        guard storedChunkSize > 0, storedChunkSize <= UInt32(maximumRecordSize) else {
            throw EncryptedFileStoreError.invalidHeader
        }

        var index: UInt64 = 0
        var totalPlaintextBytes: UInt64 = 0
        while true {
            let recordLength = try decodeUInt32(readRequired(from: input, count: 4))
            if recordLength == 0 { break }
            guard recordLength <= UInt32(maximumRecordSize) else {
                throw EncryptedFileStoreError.invalidRecord
            }
            let combined = try readRequired(from: input, count: Int(recordLength))
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(box, using: key, authenticating: chunkAAD(index: index))
                try output.write(contentsOf: plaintext)
                totalPlaintextBytes += UInt64(plaintext.count)
                index += 1
            } catch {
                throw EncryptedFileStoreError.authenticationFailed
            }
        }

        let footerChunkCount = try decodeUInt64(readRequired(from: input, count: 8))
        let footerPlaintextBytes = try decodeUInt64(readRequired(from: input, count: 8))
        let footerLength = try decodeUInt32(readRequired(from: input, count: 4))
        guard footerLength >= 28, footerLength <= 128 else {
            throw EncryptedFileStoreError.invalidRecord
        }
        let footerCombined = try readRequired(from: input, count: Int(footerLength))
        let footerValues = encode(footerChunkCount) + encode(footerPlaintextBytes)
        do {
            let box = try AES.GCM.SealedBox(combined: footerCombined)
            _ = try AES.GCM.open(box, using: key, authenticating: footerAAD(values: footerValues))
        } catch {
            throw EncryptedFileStoreError.authenticationFailed
        }

        guard footerChunkCount == index, footerPlaintextBytes == totalPlaintextBytes else {
            throw EncryptedFileStoreError.authenticationFailed
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else {
            throw EncryptedFileStoreError.invalidRecord
        }

        try output.synchronize()
        succeeded = true
    }

    private static func chunkAAD(index: UInt64) -> Data {
        magic + Data("CHUNK".utf8) + encode(index)
    }

    private static func footerAAD(values: Data) -> Data {
        magic + Data("END".utf8) + values
    }

    private static func readRequired(from handle: FileHandle, count: Int) throws -> Data {
        guard let data = try readExact(from: handle, count: count) else {
            throw EncryptedFileStoreError.truncatedFile
        }
        return data
    }

    private static func readExact(from handle: FileHandle, count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
                return result.isEmpty ? nil : nil
            }
            result.append(part)
        }
        return result
    }

    private static func encode(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ])
    }

    private static func encode(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xff) })
    }

    private static func decodeUInt32(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else { throw EncryptedFileStoreError.truncatedFile }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decodeUInt64(_ data: Data) throws -> UInt64 {
        guard data.count == 8 else { throw EncryptedFileStoreError.truncatedFile }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
