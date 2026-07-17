import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExtractedWatchedDocument: Sendable {
    var pageURLs: [URL]
    var temporaryDirectory: URL?
}

enum WatchedFilePageExtractor {
    static let supportedExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff"]

    static func extract(_ sourceURL: URL) throws -> ExtractedWatchedDocument {
        let type = try sourceURL.resourceValues(forKeys: [.contentTypeKey]).contentType
            ?? UTType(filenameExtension: sourceURL.pathExtension)
        guard let type else { throw WatchedFolderError.unsupportedFile }

        if type.conforms(to: .pdf) {
            return try splitPDF(sourceURL)
        }
        if type.conforms(to: .tiff) {
            return try splitTIFF(sourceURL)
        }
        if type.conforms(to: .jpeg) || type.conforms(to: .png) {
            try validateCompleteImage(at: sourceURL)
            return .init(pageURLs: [sourceURL], temporaryDirectory: nil)
        }
        throw WatchedFolderError.unsupportedFile
    }

    static func cleanup(_ extracted: ExtractedWatchedDocument) {
        guard let directory = extracted.temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func splitPDF(_ sourceURL: URL) throws -> ExtractedWatchedDocument {
        guard let pdf = CGPDFDocument(sourceURL as CFURL), pdf.numberOfPages > 0 else {
            throw WatchedFolderError.corruptFile
        }
        let directory = try temporaryDirectory()
        var pages: [URL] = []
        do {
            for index in 1...pdf.numberOfPages {
                guard let page = pdf.page(at: index) else { throw WatchedFolderError.corruptFile }
                var mediaBox = page.getBoxRect(.mediaBox)
                let url = directory.appendingPathComponent("page-\(index).pdf")
                guard let consumer = CGDataConsumer(url: url as CFURL),
                      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                    throw WatchedFolderError.corruptFile
                }
                context.beginPDFPage(nil)
                context.drawPDFPage(page)
                context.endPDFPage()
                context.closePDF()
                pages.append(url)
            }
            return .init(pageURLs: pages, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func splitTIFF(_ sourceURL: URL) throws -> ExtractedWatchedDocument {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw WatchedFolderError.corruptFile
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, CGImageSourceGetStatus(source) == .statusComplete else {
            throw WatchedFolderError.corruptFile
        }
        for index in 0..<count {
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  CGImageSourceCreateImageAtIndex(source, index, nil) != nil else {
                throw WatchedFolderError.corruptFile
            }
        }
        if count == 1 { return .init(pageURLs: [sourceURL], temporaryDirectory: nil) }

        let directory = try temporaryDirectory()
        var pages: [URL] = []
        do {
            for index in 0..<count {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                    throw WatchedFolderError.corruptFile
                }
                let url = directory.appendingPathComponent("page-\(index + 1).tiff")
                guard let destination = CGImageDestinationCreateWithURL(
                    url as CFURL,
                    UTType.tiff.identifier as CFString,
                    1,
                    nil
                ) else { throw WatchedFolderError.corruptFile }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                CGImageDestinationAddImage(destination, image, properties)
                guard CGImageDestinationFinalize(destination) else { throw WatchedFolderError.corruptFile }
                pages.append(url)
            }
            return .init(pageURLs: pages, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwainBridge-Watched", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private static func validateCompleteImage(at sourceURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw WatchedFolderError.corruptFile
        }
    }
}

enum WatchedFolderError: LocalizedError {
    case unsupportedFile
    case corruptFile
    case symbolicLink
    case folderUnavailable
    case permissionLost
    case outsideWatchedFolder

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: String(localized: "The file type is not supported. The source file was left untouched.")
        case .corruptFile: String(localized: "The file could not be opened. The source file was left untouched.")
        case .symbolicLink: String(localized: "Symbolic links are not imported. Choose the original file directly inside the watched folder.")
        case .folderUnavailable: String(localized: "The watched folder is unavailable. Reconnect the volume or choose the folder again.")
        case .permissionLost: String(localized: "Permission to the watched folder was lost. Choose the folder again to resume.")
        case .outsideWatchedFolder: String(localized: "Choose a file directly inside the configured watched folder. Monitoring is non-recursive.")
        }
    }
}
