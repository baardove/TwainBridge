import CryptoKit
import XCTest
@testable import TwainBridge

final class ReliabilityBoundaryTests: XCTestCase {
    func testDiskCapacityPolicyPreservesHeadroomAndRejectsOverflow() throws {
        XCTAssertNoThrow(try DiskCapacityGuard.verify(
            availableBytes: 600_000_000,
            requiredBytes: 100_000_000
        ))
        XCTAssertNoThrow(try DiskCapacityGuard.verify(
            availableBytes: nil,
            requiredBytes: 100_000_000
        ))
        XCTAssertThrowsError(try DiskCapacityGuard.verify(
            availableBytes: 599_999_999,
            requiredBytes: 100_000_000
        )) { error in
            guard case DraftStoreError.insufficientDiskSpace = error else {
                return XCTFail("Expected insufficientDiskSpace, received \(error)")
            }
        }
        XCTAssertThrowsError(try DiskCapacityGuard.verify(
            availableBytes: Int64.max,
            requiredBytes: Int64.max
        )) { error in
            guard case DraftStoreError.insufficientDiskSpace = error else {
                return XCTFail("Expected overflow to map to insufficientDiskSpace, received \(error)")
            }
        }
    }

    func testRetryPolicyUsesOnlyTransientStatusesAndCappedRetryAfter() throws {
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(statusCode: 408))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(statusCode: 425))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(statusCode: 429))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(statusCode: 503))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(statusCode: 400))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(statusCode: 5010))

        let accepted = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://receiver.example/upload")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]
        ))
        let excessive = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://receiver.example/upload")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": "301"]
        ))
        XCTAssertEqual(UploadRetryPolicy.retryDecision(response: accepted, fallback: 10), .automatic(120))
        XCTAssertEqual(
            UploadRetryPolicy.retryDecision(response: excessive, fallback: 10),
            .manualConfirmation(301)
        )

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let dated = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://receiver.example/upload")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: now.addingTimeInterval(301))]
        ))
        XCTAssertEqual(
            UploadRetryPolicy.retryDecision(response: dated, fallback: 10, now: now),
            .manualConfirmation(301)
        )
    }

    func testRetryPolicyRejectsNonTransientNetworkFailures() {
        XCTAssertTrue(UploadRetryPolicy.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(UploadRetryPolicy.isRetryable(URLError(.notConnectedToInternet)))
        XCTAssertFalse(UploadRetryPolicy.isRetryable(URLError(.badURL)))
        XCTAssertFalse(UploadRetryPolicy.isRetryable(UploadEngineError.invalidURL))
    }

    func testUploadFailureCategoriesRemainSanitizedAndActionable() {
        XCTAssertEqual(UploadFailureClassifier.category(for: URLError(.timedOut)), "timeout")
        XCTAssertEqual(
            UploadFailureClassifier.category(for: URLError(.serverCertificateUntrusted)),
            "tls_failure"
        )
        XCTAssertEqual(
            UploadFailureClassifier.category(for: UploadEngineError.longRetryDeclined),
            "retry_declined"
        )
        XCTAssertEqual(
            UploadFailureClassifier.category(for: UploadEngineError.outputSizeExceeded("safe message")),
            "output_size_exceeded"
        )
        XCTAssertEqual(UploadFailureClassifier.category(for: [
            UploadDocumentResult(
                documentID: UUID(),
                confirmation: .unconfirmed,
                requestID: UUID(),
                statusCode: 401,
                message: "A response body that must never enter history"
            )
        ]), "authentication_failure")
    }

    func testBoundedResponseBufferRejectsChunkBeforeExceedingLimit() throws {
        var buffer = BoundedResponseBuffer(maximumByteCount: 8)
        try buffer.append(Data([1, 2, 3, 4, 5]))

        XCTAssertThrowsError(try buffer.append(Data([6, 7, 8, 9]))) { error in
            guard case UploadEngineError.responseTooLarge(8) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(buffer.data, Data([1, 2, 3, 4, 5]))
    }

    func testRedirectPolicyRejectsTLSDowngradeAndStripsCrossHostSecret() throws {
        let downgradeDelegate = BoundedUploadDelegate(
            originalHost: "receiver.example",
            allowedHosts: [],
            sensitiveHeaderNames: ["Authorization"],
            maximumResponseBytes: 1_024,
            progress: { _ in }
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://receiver.example/upload")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://receiver.example/upload")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        var downgraded = URLRequest(url: URL(string: "http://receiver.example/upload")!)
        downgraded.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var downgradeResult: URLRequest?
        downgradeDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: downgraded) {
            downgradeResult = $0
        }
        XCTAssertNil(downgradeResult)

        let crossHostDelegate = BoundedUploadDelegate(
            originalHost: "receiver.example",
            allowedHosts: ["uploads.example"],
            sensitiveHeaderNames: ["Authorization"],
            maximumResponseBytes: 1_024,
            progress: { _ in }
        )
        var redirected = URLRequest(url: URL(string: "https://uploads.example/upload")!)
        redirected.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        redirected.setValue("safe", forHTTPHeaderField: "X-Correlation-ID")
        var redirectResult: URLRequest?
        crossHostDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            redirectResult = $0
        }
        XCTAssertNil(redirectResult?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(redirectResult?.value(forHTTPHeaderField: "X-Correlation-ID"), "safe")
        session.invalidateAndCancel()
    }

    func testLegacyScanRequestUsesAutomaticNewControls() throws {
        let legacy = Data(#"{"scannerID":"scanner","source":"flatbed","colorMode":"color","resolution":300,"duplex":false}"#.utf8)
        let request = try JSONDecoder().decode(ScanRequest.self, from: legacy)

        XCTAssertEqual(request.pageSize, .automatic)
        XCTAssertEqual(request.orientation, .automatic)
    }

    func testImageCaptureBusyCodeHasSafeRecoveryMessage() {
        let failure = ScannerFailure.classify(NSError(domain: "com.apple.ImageCaptureCore", code: -9925))

        XCTAssertEqual(failure.category, .busy)
        XCTAssertTrue(failure.recoverySuggestion.contains("Wait"))
        XCTAssertEqual(failure.technicalCode, "com.apple.ImageCaptureCore(-9925)")
    }

    func testLegacyTransferStateDecodesWithoutAttemptRecords() throws {
        let legacy = Data(#"{"confirmed":false,"attemptCount":2}"#.utf8)
        let state = try JSONDecoder().decode(DocumentTransferState.self, from: legacy)

        XCTAssertEqual(state.attemptCount, 2)
        XCTAssertTrue(state.attempts.isEmpty)
    }

    func testConfiguredResponseContentTypeIsEnforced() {
        let response = ResponseInterpreter.interpret(
            data: Data(#"{"success":true}"#.utf8),
            statusCode: 200,
            contentType: "text/html; charset=utf-8",
            validateContentType: true,
            configuration: ResponseConfiguration()
        )

        XCTAssertEqual(response.confirmation, .unconfirmed)
        XCTAssertTrue(response.message?.contains("Content-Type") == true)
    }

    func testSupportBundleStructurallyExcludesSensitiveOperationalValues() {
        let batchID = UUID()
        let documentID = UUID()
        let requestID = UUID()
        let draft = DraftBatch(
            id: batchID,
            documents: [],
            destinationID: UUID(),
            state: .failed,
            createdAt: Date(),
            updatedAt: Date(),
            lastErrorCategory: "network_failure",
            metadata: ["patient": "SECRET-METADATA-VALUE"]
        )
        let history = TransferHistoryEntry(
            timestamp: Date(),
            destinationName: "SECRET-DESTINATION-NAME",
            destinationHost: "private.example.test",
            documentCount: 1,
            pageCount: 1,
            result: .failed,
            remoteIDs: ["SECRET-REMOTE-ID"],
            batchID: batchID,
            documentIDs: [documentID],
            requestIDs: [requestID],
            errorCategory: "network_failure",
            openURL: URL(string: "https://private.example.test/open?token=SECRET-QUERY")
        )
        let scanner = ScannerSnapshot(
            id: "SECRET-SERIAL-NUMBER",
            name: "Epson DS-1660W",
            connection: .usb,
            location: "SECRET-IP-OR-LOCATION",
            capabilities: .unavailable
        )

        let output = DiagnosticsService.makeSupportBundle(
            scanners: [scanner],
            scannerActivity: .ready,
            drafts: [draft],
            history: [history],
            networkOnline: true,
            watchedFolderEnabled: false,
            watchedFolderStatus: .disabled
        )

        XCTAssertTrue(output.contains(batchID.uuidString))
        XCTAssertTrue(output.contains(documentID.uuidString))
        XCTAssertTrue(output.contains(requestID.uuidString))
        for prohibited in [
            "SECRET-METADATA-VALUE", "SECRET-DESTINATION-NAME", "private.example.test",
            "SECRET-REMOTE-ID", "SECRET-QUERY", "SECRET-SERIAL-NUMBER", "SECRET-IP-OR-LOCATION"
        ] {
            XCTAssertFalse(output.contains(prohibited), "Bundle leaked \(prohibited)")
        }
    }

    @MainActor
    func testDestinationHostChangeRotatesLogicalBatchWithoutMakingConfirmedDocumentActionable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let incoming = root.appendingPathComponent("incoming.tiff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000).write(to: incoming)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DraftStore(rootURL: root.appendingPathComponent("store"), keyData: Data(repeating: 4, count: 32))
        await store.reload()
        let batch = try await store.importCompletedScan(.init(
            id: UUID(),
            pageURLs: [incoming],
            request: .init(
                scannerID: "scanner",
                source: .flatbed,
                colorMode: .color,
                resolution: 300,
                duplex: false
            ),
            scannerName: "Scanner",
            completedAt: Date(),
            interrupted: false
        ))
        let documentID = try XCTUnwrap(batch.documents.first?.id)
        try await store.recordUploadResult(.init(
            documentID: documentID,
            confirmation: .confirmed,
            requestID: UUID(),
            statusCode: 200,
            message: nil,
            remoteID: "remote",
            openURL: nil
        ), batchID: batch.id)
        let originalLogicalID = try XCTUnwrap(store.selectedBatch?.logicalBatchID)

        try await store.assignDestination(UUID(), batchID: batch.id, resetLogicalBatchID: true)
        let changed = try XCTUnwrap(store.selectedBatch)
        XCTAssertNotEqual(changed.logicalBatchID, originalLogicalID)
        XCTAssertEqual(changed.actionableDocumentCount, 0)
        XCTAssertTrue(try XCTUnwrap(changed.documents.first).transfer.confirmed)

        let pageID = try XCTUnwrap(changed.documents.first?.pages.first?.id)
        do {
            try await store.rotatePage(
                batchID: changed.id,
                documentID: documentID,
                pageID: pageID,
                clockwise: true
            )
            XCTFail("Confirmed documents must be immutable")
        } catch DraftStoreError.confirmedDocumentReadOnly {
            // Expected.
        }
    }

    func testUpdateManifestSignatureRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = UpdateSignedPayload(
            version: "2.0.0",
            build: 20,
            minimumMacOS: "15.0",
            downloadURL: "https://updates.example.test/TwainBridge-2.dmg",
            sha256: String(repeating: "a", count: 64)
        )
        let signature = try privateKey.signature(for: payload.canonicalData()).base64EncodedString()
        var manifest = UpdateManifest(
            version: payload.version,
            build: payload.build,
            minimumMacOS: payload.minimumMacOS,
            downloadURL: payload.downloadURL,
            sha256: payload.sha256,
            signature: signature
        )

        XCTAssertNoThrow(try UpdateVerifier.verify(manifest, publicKey: privateKey.publicKey))
        manifest.downloadURL = "https://attacker.example.test/fake.dmg"
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest, publicKey: privateKey.publicKey))
    }
}
