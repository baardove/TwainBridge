import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TwainBridge

final class WatchedFolderTests: XCTestCase {
    func testTrackerRequiresStabilityAndPreventsDuplicateImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("scan.jpg")
        try Data(repeating: 6, count: 2_000).write(to: file)
        let tracker = WatchedFolderTracker(storageURL: root.appendingPathComponent("fingerprints.json"))
        let start = Date()

        let initial = try await tracker.stableCandidates(in: folder, now: start)
        XCTAssertTrue(initial.isEmpty)
        let ready = try await tracker.stableCandidates(in: folder, now: start.addingTimeInterval(4))
        XCTAssertEqual(ready.count, 1)
        try await tracker.markImported(try XCTUnwrap(ready.first))
        let duplicate = try await tracker.stableCandidates(in: folder, now: start.addingTimeInterval(8))
        XCTAssertTrue(duplicate.isEmpty)
        let explicitDuplicate = try await tracker.explicitCandidate(for: file)
        XCTAssertEqual(explicitDuplicate.fingerprint, ready.first?.fingerprint)

        try Data(repeating: 7, count: 2_100).write(to: file)
        let changed = try await tracker.stableCandidates(in: folder, now: start.addingTimeInterval(9))
        XCTAssertTrue(changed.isEmpty)
        let changedStable = try await tracker.stableCandidates(in: folder, now: start.addingTimeInterval(13))
        XCTAssertEqual(changedStable.count, 1)
    }

    func testTrackerRejectsSymbolicLinksOutsideWatchedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("watch", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.pdf")
        try Data("private outside content".utf8).write(to: outside)
        let link = folder.appendingPathComponent("scan.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let tracker = WatchedFolderTracker(storageURL: root.appendingPathComponent("fingerprints.json"))
        let start = Date()

        let initialCandidates = try await tracker.stableCandidates(in: folder, now: start)
        let stableCandidates = try await tracker.stableCandidates(in: folder, now: start.addingTimeInterval(4))
        XCTAssertTrue(initialCandidates.isEmpty)
        XCTAssertTrue(stableCandidates.isEmpty)
        do {
            _ = try await tracker.explicitCandidate(for: link)
            XCTFail("Expected symbolic link import to be rejected")
        } catch {
            guard case WatchedFolderError.symbolicLink = error else {
                return XCTFail("Expected symbolicLink, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("private outside content".utf8))
    }

    func testMultipageTIFFIsSplitWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("multipage.tiff")
        try makeMultipageTIFF(at: source)
        let original = try Data(contentsOf: source)

        let extracted = try WatchedFilePageExtractor.extract(source)
        defer { WatchedFilePageExtractor.cleanup(extracted) }
        XCTAssertEqual(extracted.pageURLs.count, 2)
        XCTAssertTrue(extracted.pageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMultipagePDFImportsAndReassemblesWithDocumentBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("multipage.pdf")
        try makePDF(at: source, pageCount: 2)
        let extracted = try WatchedFilePageExtractor.extract(source)
        defer { WatchedFilePageExtractor.cleanup(extracted) }
        XCTAssertEqual(extracted.pageURLs.count, 2)

        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 3, count: 32))
        let batch = try await repository.importScan(CompletedScanResult(
            id: UUID(),
            pageURLs: extracted.pageURLs,
            request: ScanRequest(scannerID: "watch", source: .automatic, colorMode: .color, resolution: 300, duplex: false),
            scannerName: "Watched Folder",
            completedAt: Date(),
            interrupted: false
        ))
        XCTAssertEqual(batch.documents.count, 1)
        XCTAssertEqual(batch.pageCount, 2)
        let outputs = try await repository.prepareOutputs(for: batch)
        XCTAssertEqual(CGPDFDocument(try XCTUnwrap(outputs.first).fileURL as CFURL)?.numberOfPages, 2)
        await repository.cleanupPreparedOutputs(outputs)
    }

    func testCorruptSupportedFilesAreRejectedWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for fileExtension in ["jpg", "tiff", "pdf"] {
            let source = root.appendingPathComponent("corrupt.\(fileExtension)")
            let original = Data("not a complete document".utf8)
            try original.write(to: source)

            XCTAssertThrowsError(try WatchedFilePageExtractor.extract(source)) { error in
                guard case WatchedFolderError.corruptFile = error else {
                    return XCTFail("Expected corruptFile for .\(fileExtension), received \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    private func image(width: Int = 40, height: Int = 60) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeMultipageTIFF(at url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            2,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, try image(), nil)
        CGImageDestinationAddImage(destination, try image(width: 50, height: 70), nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func makePDF(at url: URL, pageCount: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(index) / CGFloat(max(pageCount, 1)), alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
