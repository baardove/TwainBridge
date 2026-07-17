import Foundation

enum MultipartPart: Sendable {
    case field(name: String, value: String)
    case file(name: String, filename: String, contentType: String, url: URL)
}

struct MultipartBody: Sendable {
    var url: URL
    var boundary: String
    var byteCount: Int64
}

enum MultipartBodyBuilder {
    static func build(parts: [MultipartPart], in directory: URL) throws -> MultipartBody {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let requiredBytes = try parts.reduce(Int64(0)) { total, part in
            switch part {
            case let .field(name, value):
                return total + Int64(name.utf8.count + value.utf8.count + 256)
            case let .file(name, filename, contentType, url):
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return total + Int64(size + name.utf8.count + filename.utf8.count + contentType.utf8.count + 256)
            }
        }
        try DiskCapacityGuard.verify(at: directory, requiredBytes: requiredBytes)
        let boundary = "TwainBridge-\(UUID().uuidString)"
        let outputURL = directory.appendingPathComponent("multipart-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        let output = try FileHandle(forWritingTo: outputURL)
        var succeeded = false
        defer {
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: outputURL) }
        }

        for part in parts {
            try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            switch part {
            case let .field(name, value):
                try output.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
                try output.write(contentsOf: Data("Content-Type: text/plain; charset=utf-8\r\n\r\n".utf8))
                try output.write(contentsOf: Data(value.utf8))
                try output.write(contentsOf: Data("\r\n".utf8))
            case let .file(name, filename, contentType, url):
                try output.write(contentsOf: Data(
                    "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
                ))
                try output.write(contentsOf: Data("Content-Type: \(contentType)\r\n\r\n".utf8))
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
                try output.write(contentsOf: Data("\r\n".utf8))
            }
        }
        try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        try output.synchronize()
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        succeeded = true
        return .init(url: outputURL, boundary: boundary, byteCount: Int64(size))
    }
}
