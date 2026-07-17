import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TwainBridge

@MainActor
final class LifecycleServicesTests: XCTestCase {
    func testHistoryPrunesToFiftyEntriesAndThirtyDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldHistorySetting = UserDefaults.standard.object(forKey: "history.enabled")
        defer {
            if let oldHistorySetting { UserDefaults.standard.set(oldHistorySetting, forKey: "history.enabled") }
            else { UserDefaults.standard.removeObject(forKey: "history.enabled") }
        }
        let store = TransferHistoryStore(rootURL: root)
        store.isEnabled = true

        store.record(entry(timestamp: Date().addingTimeInterval(-31 * 24 * 60 * 60)))
        for offset in 0..<55 {
            store.record(entry(timestamp: Date().addingTimeInterval(Double(-offset))))
        }
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertTrue(store.entries.allSatisfy { $0.timestamp > Date().addingTimeInterval(-30 * 24 * 60 * 60) })
        let historyURL = root.appendingPathComponent("transfer-history.json")
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("transfer-history.json").path))
    }

    func testScanDefaultsPersistPerScanner() throws {
        let suiteName = "TwainBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanDefaultsStore(defaults: defaults)
        let request = ScanRequest(
            scannerID: "epson",
            source: .documentFeeder,
            colorMode: .grayscale,
            resolution: 600,
            duplex: true
        )
        store.save(request)
        XCTAssertEqual(ScanDefaultsStore(defaults: defaults).request(for: "epson"), request)
        XCTAssertEqual(store.request(for: "another").resolution, 300)
    }

    func testScanProfileRoundTripsOntoSelectedScanner() throws {
        let suiteName = "TwainBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScanDefaultsStore(defaults: defaults)
        let exported = ScanRequest(
            scannerID: "source-scanner",
            source: .flatbed,
            colorMode: .blackAndWhite,
            resolution: 600,
            duplex: false,
            pageSize: .a4,
            orientation: .landscape
        )

        let data = try store.exportProfile(exported)
        let imported = try store.importProfile(data, scannerID: "target-scanner")

        XCTAssertEqual(imported.scannerID, "target-scanner")
        XCTAssertEqual(imported.source, exported.source)
        XCTAssertEqual(imported.colorMode, exported.colorMode)
        XCTAssertEqual(imported.resolution, exported.resolution)
        XCTAssertEqual(imported.pageSize, exported.pageSize)
        XCTAssertEqual(imported.orientation, exported.orientation)
        XCTAssertEqual(store.request(for: "target-scanner"), imported)
    }

    func testLastOutputChoicesAndPreferredDestinationApplyToNextCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("capture.tiff")
        let suiteName = "TwainBridge.LastUsedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeTIFF(at: source, color: 0.5)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = DraftStore(
            rootURL: root.appendingPathComponent("store"),
            keyData: Data(repeating: 0x42, count: 32),
            defaults: defaults
        )
        await store.reload()
        let destinationID = UUID()
        store.preferredDestinationID = destinationID

        let first = try await store.importCompletedScan(captureResult(pageURL: source))
        let firstDocument = try XCTUnwrap(first.documents.first)
        try await store.setOutputFormat(
            batchID: first.id,
            documentID: firstDocument.id,
            format: .jpeg
        )
        try await store.setCompressionPreset(
            batchID: first.id,
            documentID: firstDocument.id,
            preset: .smaller
        )

        let second = try await store.importCompletedScan(captureResult(pageURL: source))
        XCTAssertEqual(second.destinationID, destinationID)
        XCTAssertEqual(second.documents.first?.outputFormat, .jpeg)
        XCTAssertEqual(second.documents.first?.compressionPreset, .smaller)
        XCTAssertEqual(defaults.string(forKey: "document.defaultOutputFormat"), "jpeg")
        XCTAssertEqual(defaults.string(forKey: "document.defaultCompressionPreset"), "smaller")
    }

    func testDriverStatusNeverClaimsVerifiedBelowRequiredVersion() {
        let status = DriverInspector.epsonDS1660WStatus()
        if let version = status.version,
           version.compare(DriverInspector.requiredEpsonVersion, options: .numeric) == .orderedAscending {
            XCTAssertFalse(status.verified)
        }
        if !status.installed {
            XCTAssertNil(status.version)
            XCTAssertFalse(status.verified)
        }
    }

    func testExistingEncryptedDraftDataPreventsSilentInstallationKeyReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(InstallationKeyProvider.containsEncryptedDraftData(at: root))

        let drafts = root.appendingPathComponent("Drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        try Data("ciphertext".utf8).write(
            to: drafts.appendingPathComponent(UUID().uuidString).appendingPathExtension("tbmanifest")
        )

        XCTAssertTrue(InstallationKeyProvider.containsEncryptedDraftData(at: root))
    }

    func testInterruptedScanStagingRecoversCompletedPagesAndRemovesEmptySessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = ScanRequest(
            scannerID: "epson-recovery",
            source: .documentFeeder,
            colorMode: .grayscale,
            resolution: 600,
            duplex: true,
            pageSize: .a4,
            orientation: .portrait
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try ScanStagingRecovery.createDirectory(
            rootURL: root,
            request: request,
            scannerName: "Epson DS-1660W",
            now: startedAt
        )
        let rootPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(rootPermissions.intValue & 0o777, 0o700)
        var effectiveRequest = request
        effectiveRequest.resolution = 300
        effectiveRequest.duplex = false
        try ScanStagingRecovery.updateRequest(in: session, request: effectiveRequest)
        try makeTIFF(at: session.appendingPathComponent("scan-1.tiff"), color: 0.25)
        try makeTIFF(at: session.appendingPathComponent("scan-2.tiff"), color: 0.75)
        try Data(repeating: 0x42, count: 128).write(to: session.appendingPathComponent("scan-3.tiff"))
        let empty = try ScanStagingRecovery.createDirectory(
            rootURL: root,
            request: request,
            scannerName: "Epson DS-1660W"
        )

        let recovered = ScanStagingRecovery.recover(rootURL: root)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].result.pageURLs.map(\.lastPathComponent), ["scan-1.tiff", "scan-2.tiff"])
        XCTAssertEqual(recovered[0].result.request, effectiveRequest)
        XCTAssertEqual(recovered[0].result.scannerName, "Epson DS-1660W")
        XCTAssertEqual(recovered[0].result.completedAt, startedAt)
        XCTAssertTrue(recovered[0].result.interrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    private func makeTIFF(at url: URL, color: CGFloat) throws {
        guard let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: color, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.tiff.identifier as CFString,
                  1,
                  nil
              ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    func testAutomaticOpenURLRequiresPerHostApproval() throws {
        let suiteName = "TwainBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = try XCTUnwrap(URL(string: "https://records.example.test/cases/1"))
        let sameHost = try XCTUnwrap(URL(string: "https://records.example.test/cases/2"))
        let otherHost = try XCTUnwrap(URL(string: "https://other.example.test/cases/1"))

        XCTAssertFalse(OpenURLApprovalStore.isApproved(first, defaults: defaults))
        OpenURLApprovalStore.approve(first, defaults: defaults)
        XCTAssertTrue(OpenURLApprovalStore.isApproved(sameHost, defaults: defaults))
        XCTAssertFalse(OpenURLApprovalStore.isApproved(otherHost, defaults: defaults))
        XCTAssertFalse(OpenURLApprovalStore.isApproved(URL(string: "http://records.example.test")!, defaults: defaults))
    }

    private func entry(timestamp: Date) -> TransferHistoryEntry {
        .init(
            timestamp: timestamp,
            destinationName: "Destination",
            destinationHost: "example.test",
            documentCount: 1,
            pageCount: 2,
            result: .sent,
            remoteIDs: ["remote"],
            batchID: UUID(),
            documentIDs: [UUID()],
            requestIDs: [UUID()],
            errorCategory: nil,
            openURL: nil
        )
    }

    private func captureResult(pageURL: URL) -> CompletedScanResult {
        .init(
            id: UUID(),
            pageURLs: [pageURL],
            request: .init(
                scannerID: "repeat-scanner",
                source: .flatbed,
                colorMode: .color,
                resolution: 300,
                duplex: false
            ),
            scannerName: "Repeat Scanner",
            completedAt: Date(),
            interrupted: false
        )
    }
}
