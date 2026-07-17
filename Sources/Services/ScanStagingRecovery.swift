import CoreGraphics
import Foundation
import ImageIO

struct ScanStagingMetadata: Codable, Equatable, Sendable {
    static let filename = ".scan-metadata.json"

    var resultID: UUID
    var request: ScanRequest
    var scannerName: String
    var startedAt: Date
}

struct RecoveredStagingScan: Sendable {
    var directory: URL
    var result: CompletedScanResult
}

enum ScanStagingRecovery {
    static var defaultRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TwainBridge", isDirectory: true)
    }

    static func createDirectory(
        rootURL: URL = defaultRootURL,
        request: ScanRequest,
        scannerName: String,
        now: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        let directory = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let metadata = ScanStagingMetadata(
            resultID: UUID(),
            request: request,
            scannerName: scannerName,
            startedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataURL = directory.appendingPathComponent(ScanStagingMetadata.filename)
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        return directory
    }

    static func recover(rootURL: URL = defaultRootURL) -> [RecoveredStagingScan] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recovered: [RecoveredStagingScan] = []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let pages = eligiblePages(in: directory)
            guard !pages.isEmpty else {
                try? FileManager.default.removeItem(at: directory)
                continue
            }
            let metadata = readMetadata(from: directory)
            let request = metadata?.request ?? ScanRequest(
                scannerID: "recovered-scan",
                source: .automatic,
                colorMode: .color,
                resolution: 300,
                duplex: false
            )
            recovered.append(.init(
                directory: directory,
                result: CompletedScanResult(
                    id: metadata?.resultID ?? UUID(),
                    pageURLs: pages,
                    request: request,
                    scannerName: metadata?.scannerName ?? String(localized: "Recovered Scan"),
                    completedAt: metadata?.startedAt ?? values?.contentModificationDate ?? Date(),
                    interrupted: true
                )
            ))
        }
        return recovered.sorted { $0.result.completedAt < $1.result.completedAt }
    }

    static func updateRequest(in directory: URL, request: ScanRequest) throws {
        let metadataURL = directory.appendingPathComponent(ScanStagingMetadata.filename)
        guard var metadata = readMetadata(from: directory) else { return }
        metadata.request = request
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    private static func readMetadata(from directory: URL) -> ScanStagingMetadata? {
        let url = directory.appendingPathComponent(ScanStagingMetadata.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanStagingMetadata.self, from: data)
    }

    private static func eligiblePages(in directory: URL) -> [URL] {
        let extensions: Set<String> = ["tif", "tiff", "jpg", "jpeg", "png", "pdf"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return files.filter { file in
            guard extensions.contains(file.pathExtension.lowercased()) else { return false }
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return isCompletePage(file)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isCompletePage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" {
            return CGPDFDocument(url as CFURL).map { $0.numberOfPages > 0 } ?? false
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let count = CGImageSourceGetCount(source)
        guard count > 0, CGImageSourceGetStatus(source) == .statusComplete else { return false }
        return (0..<count).allSatisfy {
            CGImageSourceGetStatusAtIndex(source, $0) == .statusComplete
                && CGImageSourceCreateImageAtIndex(source, $0, nil) != nil
        }
    }
}
