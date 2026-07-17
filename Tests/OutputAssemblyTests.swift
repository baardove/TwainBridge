import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TwainBridge

final class OutputAssemblyTests: XCTestCase {
    func testHundredPagePDFAssemblyCompletesWithEveryPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTIFF(at: incoming, width: 24, height: 32, dpi: 100)

        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 5, count: 32)
        )
        var batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: Array(repeating: incoming, count: 100),
            request: .init(
                scannerID: "scale-test",
                source: .documentFeeder,
                colorMode: .color,
                resolution: 100,
                duplex: true
            ),
            scannerName: "Scale Test",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .pdf
        let outputs = try await repository.prepareOutputs(for: batch)
        defer { Task { await repository.cleanupPreparedOutputs(outputs) } }

        let pdf = try XCTUnwrap(CGPDFDocument(outputs[0].fileURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 100)
    }

    func testPDFAssemblyPreservesPageCountRotationAndSafeFilename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = incoming.appendingPathComponent("one.tiff")
        let second = incoming.appendingPathComponent("two.tiff")
        try makeTIFF(at: first, width: 100, height: 200, dpi: 100)
        try makeTIFF(at: second, width: 100, height: 200, dpi: 100)

        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 8, count: 32)
        )
        var batch = try await repository.importScan(CompletedScanResult(
            id: UUID(),
            pageURLs: [first, second],
            request: ScanRequest(
                scannerID: "scanner",
                source: .flatbed,
                colorMode: .color,
                resolution: 100,
                duplex: false
            ),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].name = "../../Bad:\nName"
        batch.documents[0].outputFormat = .pdf
        batch.documents[0].pages[0].rotation = .clockwise90

        let outputs = try await repository.prepareOutputs(for: batch)
        let output = try XCTUnwrap(outputs.first)
        let outputPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: output.fileURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(outputPermissions.intValue & 0o777, 0o600)
        XCTAssertFalse(output.filename.contains("/"))
        XCTAssertFalse(output.filename.contains("\n"))
        let pdf = try XCTUnwrap(CGPDFDocument(output.fileURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        let firstPage = try XCTUnwrap(pdf.page(at: 1))
        let box = firstPage.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 144, accuracy: 1)
        XCTAssertEqual(box.height, 72, accuracy: 1)
        await repository.cleanupPreparedOutputs(outputs)
    }

    func testPDFImageContentIsNotVerticallyInverted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTIFF(at: incoming, width: 120, height: 80, dpi: 100)

        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 4, count: 32)
        )
        var batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(
                scannerID: "orientation-test",
                source: .flatbed,
                colorMode: .color,
                resolution: 100,
                duplex: false
            ),
            scannerName: "Orientation Test",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .pdf
        let outputs = try await repository.prepareOutputs(for: batch)
        defer { Task { await repository.cleanupPreparedOutputs(outputs) } }

        let outputURL = try XCTUnwrap(outputs.first).fileURL
        guard let pdf = CGPDFDocument(outputURL as CFURL) else {
            XCTFail("Generated PDF could not be opened")
            return
        }
        let page = try XCTUnwrap(pdf.page(at: 1))
        let matrices = pdfConcatenationMatrices(in: page)

        XCTAssertFalse(matrices.isEmpty)
        XCTAssertFalse(matrices.contains { $0.d < 0 }, "A negative vertical scale flips the embedded image in the PDF.")
    }

    func testJPEGOutputRejectsMultiplePages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = incoming.appendingPathComponent("page.tiff")
        try makeTIFF(at: page, width: 20, height: 20, dpi: 100)
        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 1, count: 32))
        var batch = try await repository.importScan(CompletedScanResult(
            id: UUID(),
            pageURLs: [page, page],
            request: ScanRequest(scannerID: "s", source: .flatbed, colorMode: .color, resolution: 100, duplex: false),
            scannerName: "S",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .jpeg
        do {
            _ = try await repository.prepareOutputs(for: batch)
            XCTFail("Expected JPEG page-count validation")
        } catch OutputAssemblyError.jpegRequiresSinglePage {
            // Expected.
        }
    }

    func testSmallerCompressionPresetReducesJPEGPixelDimensions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = incoming.appendingPathComponent("page.tiff")
        try makeTIFF(at: page, width: 1_000, height: 800, dpi: 200)
        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 3, count: 32)
        )
        var batch = try await repository.importScan(CompletedScanResult(
            id: UUID(),
            pageURLs: [page],
            request: ScanRequest(scannerID: "s", source: .flatbed, colorMode: .color, resolution: 200, duplex: false),
            scannerName: "S",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .jpeg
        batch.documents[0].compressionPreset = .smaller

        let outputs = try await repository.prepareOutputs(for: batch)
        defer { Task { await repository.cleanupPreparedOutputs(outputs) } }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outputs[0].fileURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 600)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 480)
    }

    func testDestinationFilenamePatternRendersIdentifiersAndSafeExtension() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTIFF(at: incoming, width: 50, height: 50, dpi: 100)
        let repository = try DraftRepository(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 2, count: 32))
        var batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(scannerID: "s", source: .flatbed, colorMode: .color, resolution: 100, duplex: false),
            scannerName: "S",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .pdf
        let outputs = try await repository.prepareOutputs(
            for: batch,
            filenamePattern: "scan-{index}-{document_id}"
        )
        defer { Task { await repository.cleanupPreparedOutputs(outputs) } }
        XCTAssertTrue(outputs[0].filename.hasPrefix("scan-1-\(batch.documents[0].id.uuidString)"))
        XCTAssertTrue(outputs[0].filename.hasSuffix(".pdf"))
    }

    func testOutputAssemblyCanSaveOnlyTheSelectedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTIFF(at: incoming, width: 40, height: 60, dpi: 100)
        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 4, count: 32)
        )
        let result = CompletedScanResult(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(scannerID: "s", source: .flatbed, colorMode: .color, resolution: 100, duplex: false),
            scannerName: "S",
            completedAt: Date(),
            interrupted: false
        )
        var batch = try await repository.importScan(result)
        batch = try await repository.importScan(
            result,
            existingBatch: batch,
            target: .newDocument(batchID: batch.id)
        )
        for index in batch.documents.indices { batch.documents[index].outputFormat = .pdf }
        let selectedID = batch.documents[1].id

        let outputs = try await repository.prepareOutputs(
            for: batch,
            documentIDs: Set([selectedID])
        )
        defer { Task { await repository.cleanupPreparedOutputs(outputs) } }

        XCTAssertEqual(outputs.map(\.id), [selectedID])
        XCTAssertEqual(CGPDFDocument(try XCTUnwrap(outputs.first).fileURL as CFURL)?.numberOfPages, 1)
    }

    func testLibraryExportCanIncludeConfirmedDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("page.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTIFF(at: incoming, width: 40, height: 60, dpi: 100)
        let repository = try DraftRepository(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 0x31, count: 32)
        )
        var batch = try await repository.importScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(scannerID: "scanner", source: .flatbed, colorMode: .color, resolution: 100, duplex: false),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        batch.documents[0].outputFormat = .pdf
        batch.documents[0].transfer.confirmed = true

        let ordinaryOutputs = try await repository.prepareOutputs(for: batch)
        XCTAssertTrue(ordinaryOutputs.isEmpty)
        let libraryOutputs = try await repository.prepareOutputs(for: batch, includeConfirmed: true)
        defer { Task { await repository.cleanupPreparedOutputs(libraryOutputs) } }

        XCTAssertEqual(libraryOutputs.count, 1)
        XCTAssertEqual(CGPDFDocument(libraryOutputs[0].fileURL as CFURL)?.numberOfPages, 1)
    }

    private func makeTIFF(at url: URL, width: Int, height: Int, dpi: Int) throws {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.tiff.identifier as CFString,
                1,
                nil
              ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private final class PDFMatrixCollector {
    var matrices: [CGAffineTransform] = []
}

private let collectPDFMatrix: CGPDFOperatorCallback = { scanner, info in
    guard let info else { return }
    var values = Array(repeating: CGPDFReal(0), count: 6)
    for index in stride(from: 5, through: 0, by: -1) {
        guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
    }
    Unmanaged<PDFMatrixCollector>.fromOpaque(info).takeUnretainedValue().matrices.append(
        CGAffineTransform(
            a: values[0], b: values[1], c: values[2],
            d: values[3], tx: values[4], ty: values[5]
        )
    )
}

private func pdfConcatenationMatrices(in page: CGPDFPage) -> [CGAffineTransform] {
    guard let table = CGPDFOperatorTableCreate() else { return [] }
    let stream = CGPDFContentStreamCreateWithPage(page)
    CGPDFOperatorTableSetCallback(table, "cm", collectPDFMatrix)
    let collector = PDFMatrixCollector()
    let scanner = CGPDFScannerCreate(
        stream,
        table,
        Unmanaged.passUnretained(collector).toOpaque()
    )
    _ = CGPDFScannerScan(scanner)
    return collector.matrices
}

final class MultipartBodyBuilderTests: XCTestCase {
    func testHundredMiBFileIsStreamedIntoMultipartBody() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.pdf")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        let chunk = Data(repeating: 0x41, count: 1_048_576)
        for _ in 0..<100 { try writer.write(contentsOf: chunk) }
        try writer.close()

        let body = try MultipartBodyBuilder.build(parts: [
            .file(name: "file", filename: "large.pdf", contentType: "application/pdf", url: file)
        ], in: root)
        let bodyPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: body.url.path)[.posixPermissions] as? NSNumber
        )

        XCTAssertGreaterThan(body.byteCount, 100 * 1_048_576)
        XCTAssertEqual(bodyPermissions.intValue & 0o777, 0o600)
        let reader = try FileHandle(forReadingFrom: body.url)
        let prefix = try XCTUnwrap(try reader.read(upToCount: 512))
        try reader.close()
        XCTAssertTrue(String(decoding: prefix, as: UTF8.self).contains("filename=\"large.pdf\""))
    }

    func testMultipartBodyContainsFieldsAndStreamsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.pdf")
        try Data(repeating: 0x5a, count: 2_200_000).write(to: file)
        let body = try MultipartBodyBuilder.build(parts: [
            .field(name: "document_id", value: "doc-123"),
            .file(name: "file", filename: "document.pdf", contentType: "application/pdf", url: file)
        ], in: root)
        let data = try Data(contentsOf: body.url)
        let textPrefix = String(decoding: data.prefix(1_000), as: UTF8.self)
        XCTAssertTrue(textPrefix.contains("document_id"))
        XCTAssertTrue(textPrefix.contains("doc-123"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("filename=\"document.pdf\""))
        XCTAssertGreaterThan(body.byteCount, 2_200_000)
    }
}
