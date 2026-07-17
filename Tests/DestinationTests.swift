import CoreGraphics
import XCTest
@testable import TwainBridge

@MainActor
final class DestinationTests: XCTestCase {
    func testAdditionalPageDecisionEnforcesDestinationPolicyBeforeScanning() {
        var profile = DestinationProfile()
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 1), .appendToCurrentDocument)

        profile.pagePolicy = .singlePage
        profile.singlePageOverflow = .startNewDocument
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 1), .startNewDocument)
        profile.singlePageOverflow = .ask
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 1), .askToStartNewDocument)
        profile.singlePageOverflow = .reject
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 1), .rejectSinglePage)

        profile.pagePolicy = .multiplePages
        profile.maximumPagesPerDocument = 3
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 2), .appendToCurrentDocument)
        XCTAssertEqual(profile.additionalPageDecision(currentPageCount: 3), .maximumPagesReached(3))

        profile.pagePolicy = .singlePage
        profile.singlePageOverflow = .startNewDocument
        XCTAssertEqual(profile.projectedOutboundDocumentCount(pageCounts: [3, 2]), 5)
        profile.singlePageOverflow = .reject
        XCTAssertEqual(profile.projectedOutboundDocumentCount(pageCounts: [3, 2]), 2)
    }

    func testConnectionFixturePDFIsAValidSinglePageDocument() throws {
        let data = try XCTUnwrap(DestinationConnectionTester.generatedTestPDFData())
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))

        XCTAssertEqual(document.numberOfPages, 1)
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
    }

    func testRememberedNonSensitiveParameterValueIsDestinationScopedAndKeychainBacked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        var profile = store.createDestination()
        let parameter = DestinationParameter(
            name: "department",
            valueSource: .userEntered,
            rememberValue: true
        )
        profile.parameters = [parameter]
        try store.save(profile)
        defer { try? store.delete(profile.id) }

        try store.setRememberedParameterValue("Accounting", profileID: profile.id, parameterID: parameter.id)

        XCTAssertEqual(
            store.rememberedParameterValue(profileID: profile.id, parameterID: parameter.id),
            "Accounting"
        )
        let storageURL = root.appendingPathComponent("destinations.json")
        XCTAssertFalse(String(decoding: try Data(contentsOf: storageURL), as: UTF8.self).contains("Accounting"))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: storageURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testLastSelectedDestinationPersistsAcrossRestarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        let first = store.createDestination()
        let second = store.createDestination()
        store.setDefault(first.id)
        store.selectedDestinationID = second.id

        let restored = DestinationStore(rootURL: root)
        XCTAssertEqual(restored.defaultDestinationID, first.id)
        XCTAssertEqual(restored.selectedDestinationID, second.id)

        try? restored.delete(first.id)
        try? restored.delete(second.id)
    }

    func testDestinationCollectionWithoutLastSelectionRemainsDecodable() throws {
        let legacy = Data(#"{"version":1,"defaultDestinationID":null,"profiles":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(DestinationCollection.self, from: legacy)
        XCTAssertNil(decoded.lastSelectedDestinationID)
        XCTAssertTrue(decoded.profiles.isEmpty)
    }

    func testRememberedSensitiveUserValueSurvivesProfileSaveOnlyInKeychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        var profile = store.createDestination()
        let parameter = DestinationParameter(
            name: "operator_pin",
            valueSource: .userEntered,
            sensitive: true,
            rememberValue: true
        )
        profile.parameters = [parameter]
        try store.save(profile)
        defer { try? store.delete(profile.id) }

        try store.setRememberedParameterValue("1234", profileID: profile.id, parameterID: parameter.id)
        try store.save(profile)

        XCTAssertEqual(
            store.rememberedParameterValue(profileID: profile.id, parameterID: parameter.id),
            "1234"
        )
        let storedProfile = String(
            decoding: try Data(contentsOf: root.appendingPathComponent("destinations.json")),
            as: UTF8.self
        )
        XCTAssertFalse(storedProfile.contains("1234"))
    }

    func testClearingOrDisablingAuthenticationDeletesStoredCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        var profile = store.createDestination()
        defer { try? store.delete(profile.id) }

        profile.authentication.kind = .bearerToken
        try store.save(profile, credential: "temporary-secret")
        XCTAssertEqual(store.credential(for: profile.id), "temporary-secret")

        try store.save(profile, credential: "")
        XCTAssertNil(store.credential(for: profile.id))

        try store.save(profile, credential: "replacement-secret")
        XCTAssertEqual(store.credential(for: profile.id), "replacement-secret")

        profile.authentication.kind = .none
        try store.save(profile, credential: "replacement-secret")
        XCTAssertNil(store.credential(for: profile.id))
    }

    func testTypedParameterValidationCoversBoundsChoicesDatesAndPatterns() {
        var integer = DestinationParameter(
            name: "copies",
            dataType: .integer,
            required: true,
            minimum: 1,
            maximum: 5
        )
        XCTAssertNil(DestinationParameterValidator.validate(value: "3", for: integer))
        XCTAssertNotNil(DestinationParameterValidator.validate(value: "3.5", for: integer))
        XCTAssertNotNil(DestinationParameterValidator.validate(value: "7", for: integer))

        var choice = DestinationParameter(name: "department", dataType: .choice, allowedValues: ["Sales", "Support"])
        XCTAssertNil(DestinationParameterValidator.validate(value: "Sales", for: choice))
        XCTAssertNotNil(DestinationParameterValidator.validate(value: "Other", for: choice))
        choice.allowedValues = []
        XCTAssertNotNil(DestinationParameterValidator.configurationIssue(for: choice))

        var date = DestinationParameter(name: "received", dataType: .date)
        XCTAssertNil(DestinationParameterValidator.validate(value: "2026-07-17", for: date))
        XCTAssertNotNil(DestinationParameterValidator.validate(value: "17/07/2026", for: date))
        date.validationExpression = "["
        XCTAssertNotNil(DestinationParameterValidator.configurationIssue(for: date))
        integer.minimum = 10
        integer.maximum = 2
        XCTAssertNotNil(DestinationParameterValidator.configurationIssue(for: integer))
    }

    func testDocumentScopedEphemeralValuesRemainDistinct() {
        let parameterID = UUID()
        let firstDocumentID = UUID()
        let secondDocumentID = UUID()
        let values: [ParameterValueKey: String] = [
            .init(parameterID: parameterID, documentID: firstDocumentID): "first",
            .init(parameterID: parameterID, documentID: secondDocumentID): "second"
        ]
        XCTAssertEqual(values[.init(parameterID: parameterID, documentID: firstDocumentID)], "first")
        XCTAssertEqual(values[.init(parameterID: parameterID, documentID: secondDocumentID)], "second")
    }

    func testStrictResponseMappingRejectsMissingOrInvalidOptionalFields() {
        var configuration = ResponseConfiguration()
        configuration.missingOptionalFieldsAllowed = false
        let missing = ResponseInterpreter.interpret(
            data: Data(#"{"success":true}"#.utf8),
            statusCode: 200,
            contentType: "application/json",
            validateContentType: true,
            configuration: configuration
        )
        XCTAssertEqual(missing.confirmation, .unconfirmed)

        configuration.missingOptionalFieldsAllowed = true
        let invalidURL = ResponseInterpreter.interpret(
            data: Data(#"{"success":true,"open_url":"not a URL"}"#.utf8),
            statusCode: 200,
            contentType: "application/json",
            validateContentType: true,
            configuration: configuration
        )
        XCTAssertEqual(invalidURL.confirmation, .unconfirmed)
    }

    func testRequestComposerEmitsDynamicHeadersQueryAndPerDocumentManifestValues() throws {
        let now = Date()
        let firstID = UUID()
        let secondID = UUID()
        let first = DraftDocument(
            id: firstID,
            name: "First",
            pages: [],
            scanSettings: .init(scannerID: "scanner", scannerName: "Scanner", source: .flatbed, colorMode: .color, resolution: 300, duplex: false),
            outputFormat: .pdf,
            compressionPreset: nil,
            metadata: [:],
            transfer: .init(),
            createdAt: now,
            updatedAt: now
        )
        var second = first
        second.id = secondID
        second.name = "Second"
        let batch = DraftBatch(
            id: UUID(),
            documents: [first, second],
            destinationID: nil,
            state: .ready,
            createdAt: now,
            updatedAt: now,
            lastErrorCategory: nil
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.pdf")
        let secondFile = root.appendingPathComponent("second.pdf")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)
        let outputs = [
            PreparedDocument(id: firstID, fileURL: firstFile, filename: "first.pdf", contentType: "application/pdf", byteCount: 5, pageCount: 1),
            PreparedDocument(id: secondID, fileURL: secondFile, filename: "second.pdf", contentType: "application/pdf", byteCount: 6, pageCount: 1)
        ]

        let documentValue = DestinationParameter(name: "case_number", location: .form, valueSource: .userEntered, scope: .document)
        let batchHeader = DestinationParameter(name: "X-Batch-ID", location: .header, valueSource: .builtIn, scope: .batch, builtInValue: .batchID)
        let attemptHeader = DestinationParameter(name: "X-Attempt-ID", location: .header, valueSource: .builtIn, scope: .request, builtInValue: .requestID)
        let query = DestinationParameter(name: "tenant", location: .query, valueSource: .fixed, scope: .request, value: "north")
        let secretHeader = DestinationParameter(name: "X-Receiver-Secret", location: .header, valueSource: .fixed, scope: .request, sensitive: true)
        var configuredProfile = DestinationProfile()
        configuredProfile.endpointURL = "https://receiver.example/upload/{batch_id}/{tenant}"
        configuredProfile.batchPolicy = .multipleDocuments
        configuredProfile.fileFieldConvention = .customPerDocument
        configuredProfile.customFileFieldPattern = "documents[{index}][{document_id}]"
        configuredProfile.parameters = [documentValue, batchHeader, attemptHeader, query, secretHeader]
        let values: [ParameterValueKey: String] = [
            .init(parameterID: documentValue.id, documentID: firstID): "A-1",
            .init(parameterID: documentValue.id, documentID: secondID): "B-2",
            .init(parameterID: secretHeader.id, documentID: nil): "secret-value"
        ]
        let context = UploadEngine.Context(
            batch: batch,
            outputs: outputs,
            profile: configuredProfile,
            credential: nil,
            parameterValues: values
        )
        let engine = UploadEngine()
        let attemptRequestID = UUID()
        let parts = engine.multipartParts(context: context, document: nil, requestID: attemptRequestID)
        let fileFields = parts.compactMap { part -> String? in
            guard case let .file(name, _, _, _) = part else { return nil }
            return name
        }
        XCTAssertEqual(fileFields, [
            "documents[0][\(firstID.uuidString)]",
            "documents[1][\(secondID.uuidString)]"
        ])
        let manifest = try XCTUnwrap(parts.compactMap { part -> String? in
            guard case let .field(name, value) = part, name == "manifest" else { return nil }
            return value
        }.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["documents"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["document_id"] as? String == firstID.uuidString }?["case_number"] as? String, "A-1")
        XCTAssertEqual(rows.first { $0["document_id"] as? String == secondID.uuidString }?["case_number"] as? String, "B-2")
        let multipartRequestID = parts.compactMap { part -> String? in
            guard case let .field(name, value) = part, name == "request_id" else { return nil }
            return value
        }.first
        XCTAssertEqual(multipartRequestID, attemptRequestID.uuidString)

        let request = try engine.makeRequest(
            context: context,
            document: nil,
            requestID: attemptRequestID,
            body: MultipartBody(url: firstFile, boundary: "boundary", byteCount: 5)
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Batch-ID"), batch.logicalBatchID.uuidString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Attempt-ID"), attemptRequestID.uuidString)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Receiver-Secret"), "secret-value")
        XCTAssertEqual(request.url?.path, "/upload/\(batch.logicalBatchID.uuidString)/north")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tenant" }?.value, "north")
    }

    func testCustomFileFieldPatternRequiresPerDocumentIdentity() {
        var profile = DestinationProfile()
        profile.endpointURL = "https://receiver.example/upload"
        profile.fileFieldConvention = .customPerDocument
        profile.customFileFieldPattern = "documents[]"
        XCTAssertTrue(DestinationValidator.validate(profile, hasAuthenticationSecret: true).contains {
            $0.id == "file-field.pattern"
        })

        profile.customFileFieldPattern = "documents[{index}]"
        XCTAssertFalse(DestinationValidator.validate(profile, hasAuthenticationSecret: true).contains {
            $0.id == "file-field.pattern"
        })
    }

    func testURLTemplateValidationRejectsSecretsAndAmbiguousDocumentValues() {
        var secretProfile = DestinationProfile()
        secretProfile.endpointURL = "https://receiver.example/upload/{token}"
        secretProfile.parameters = [DestinationParameter(
            name: "token",
            location: .header,
            valueSource: .fixed,
            sensitive: true
        )]
        XCTAssertTrue(DestinationValidator.validate(secretProfile, hasAuthenticationSecret: true).contains {
            $0.id == "url.placeholder"
        })

        var batchProfile = DestinationProfile()
        batchProfile.endpointURL = "https://receiver.example/documents/{document_id}"
        batchProfile.batchPolicy = .multipleDocuments
        batchProfile.batchRequestMode = .oneMultipartRequest
        XCTAssertTrue(DestinationValidator.validate(batchProfile, hasAuthenticationSecret: true).contains {
            $0.id == "url.placeholder"
        })
    }

    func testBatchResponseMarksEveryOmittedDocumentUnconfirmed() throws {
        let firstID = UUID()
        let secondID = UUID()
        let outputs = [firstID, secondID].map { id in
            PreparedDocument(
                id: id,
                fileURL: URL(fileURLWithPath: "/tmp/unused"),
                filename: "unused.pdf",
                contentType: "application/pdf",
                byteCount: 0,
                pageCount: 1
            )
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "documents": [["document_id": firstID.uuidString, "success": true]]
        ])

        let results = UploadEngine().parsePerDocumentResults(
            data: data,
            outputs: outputs,
            requestID: UUID(),
            statusCode: 200,
            profile: DestinationProfile(),
            attemptCount: 1
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first { $0.documentID == firstID }?.confirmation, .confirmed)
        XCTAssertEqual(results.first { $0.documentID == secondID }?.confirmation, .unconfirmed)
    }

    func testAmbiguousSuccessfulResponsesRequireIdempotentRetry() throws {
        let firstID = UUID()
        let secondID = UUID()
        var profile = DestinationProfile()
        profile.endpointURL = "https://receiver.example/upload"
        let context = UploadEngine.Context(
            batch: DraftBatch(
                id: UUID(),
                documents: [],
                destinationID: nil,
                state: .ready,
                createdAt: Date(),
                updatedAt: Date(),
                lastErrorCategory: nil
            ),
            outputs: [],
            profile: profile,
            credential: nil,
            parameterValues: [:]
        )
        let engine = UploadEngine()

        XCTAssertTrue(engine.responseRequiresIdempotentRetry(
            data: Data("{malformed".utf8),
            statusCode: 200,
            contentType: "application/json",
            context: context,
            documentIDs: [firstID]
        ))

        let incomplete = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "documents": [["document_id": firstID.uuidString, "success": true]]
        ])
        XCTAssertTrue(engine.responseRequiresIdempotentRetry(
            data: incomplete,
            statusCode: 200,
            contentType: "application/json",
            context: context,
            documentIDs: [firstID, secondID]
        ))

        let complete = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "documents": [
                ["document_id": firstID.uuidString, "success": true],
                ["document_id": secondID.uuidString, "success": false]
            ]
        ])
        XCTAssertFalse(engine.responseRequiresIdempotentRetry(
            data: complete,
            statusCode: 200,
            contentType: "application/json",
            context: context,
            documentIDs: [firstID, secondID]
        ))
    }

    func testValidatorRejectsHTTPReservedHeadersAndSensitiveQuery() {
        var profile = DestinationProfile()
        profile.endpointURL = "http://example.test/upload"
        profile.parameters = [
            DestinationParameter(name: "Host", location: .header, value: "bad"),
            DestinationParameter(name: "token", location: .query, value: nil, required: true, sensitive: true)
        ]

        let issues = DestinationValidator.validate(profile, hasAuthenticationSecret: true)
        XCTAssertTrue(issues.contains { $0.id == "url.https" })
        XCTAssertTrue(issues.contains { $0.id.contains("reserved") })
        XCTAssertTrue(issues.contains { $0.id.contains("query-secret") })
    }

    func testValidatorAllowsHTTPForLocalNetworkDestinationsOnly() throws {
        let allowedHosts = [
            "localhost", "127.0.0.1", "10.24.5.8", "172.16.0.1", "172.26.4.9",
            "172.31.255.254", "192.168.50.12", "169.254.2.3", "receiver.local",
            "twainbridge-demo", "[::1]", "[fd12:3456::10]", "[fe80::20]"
        ]
        for host in allowedHosts {
            var profile = DestinationProfile()
            profile.endpointURL = "http://\(host):9080/upload"
            let issues = DestinationValidator.validate(profile, hasAuthenticationSecret: true)
            XCTAssertFalse(issues.contains { $0.id == "url.https" }, "Expected local HTTP host to be allowed: \(host)")
            XCTAssertTrue(DestinationValidator.isAllowedTransportURL(try XCTUnwrap(URL(string: profile.endpointURL))))
        }

        let rejectedHosts = ["example.com", "172.15.0.1", "172.32.0.1", "192.169.1.1", "8.8.8.8"]
        for host in rejectedHosts {
            var profile = DestinationProfile()
            profile.endpointURL = "http://\(host)/upload"
            let issues = DestinationValidator.validate(profile, hasAuthenticationSecret: true)
            XCTAssertTrue(issues.contains { $0.id == "url.https" }, "Expected public HTTP host to be rejected: \(host)")
            XCTAssertFalse(DestinationValidator.isAllowedTransportURL(try XCTUnwrap(URL(string: profile.endpointURL))))
        }
    }

    func testValidatorRejectsTransportFieldAndHeaderCollisions() {
        var profile = DestinationProfile()
        profile.endpointURL = "https://example.test/upload?token=unsafe"
        profile.parameters = [
            DestinationParameter(name: "Content-Type", location: .header, value: "text/plain"),
            DestinationParameter(name: "batch_id", location: .form, value: "override"),
            DestinationParameter(name: "file", location: .form, value: "override")
        ]

        let issues = DestinationValidator.validate(profile, hasAuthenticationSecret: true)
        XCTAssertTrue(issues.contains { $0.id == "url.query" })
        XCTAssertTrue(issues.contains { $0.id.contains("reserved") })
        XCTAssertEqual(issues.filter { $0.id.contains("transport-field") }.count, 2)
    }

    func testExportedProfileOmitsSensitiveValuesAndClearsTestStatus() throws {
        var profile = DestinationProfile()
        profile.endpointURL = "https://example.test/upload"
        profile.enabled = true
        profile.lastConnectionTestSucceeded = true
        profile.parameters = [
            DestinationParameter(
                name: "X-Secret",
                location: .header,
                value: "must-not-export",
                required: true,
                sensitive: true
            )
        ]

        let data = try JSONEncoder().encode(profile.exportedCopy())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("must-not-export"))
        let decoded = try JSONDecoder().decode(DestinationProfile.self, from: data)
        XCTAssertNil(decoded.parameters.first?.value)
        XCTAssertFalse(decoded.enabled)
        XCTAssertFalse(decoded.lastConnectionTestSucceeded)
    }

    func testConnectionResultDoesNotChangeDestinationEnablement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        var profile = store.createDestination()
        profile.enabled = true
        try store.save(profile)

        try store.recordConnectionTest(
            profileID: profile.id,
            result: .init(outcome: .serverFailure, statusCode: 500, summary: "Test failure")
        )
        XCTAssertEqual(store.profile(id: profile.id)?.enabled, true)
        XCTAssertEqual(store.profile(id: profile.id)?.lastConnectionTestSucceeded, false)

        profile = try XCTUnwrap(store.profile(id: profile.id))
        profile.enabled = false
        try store.save(profile)
        try store.recordConnectionTest(
            profileID: profile.id,
            result: .init(outcome: .success, statusCode: 200, summary: "Test success")
        )
        XCTAssertEqual(store.profile(id: profile.id)?.enabled, false)
        XCTAssertEqual(store.profile(id: profile.id)?.lastConnectionTestSucceeded, true)
    }

    func testStandardResponseRequiresConfirmedApplicationSuccess() throws {
        let successData = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "id": "remote-42",
            "message": "Accepted"
        ])
        let success = ResponseInterpreter.interpret(
            data: successData,
            statusCode: 200,
            configuration: ResponseConfiguration()
        )
        XCTAssertEqual(success.confirmation, .confirmed)
        XCTAssertEqual(success.remoteID, "remote-42")

        let malformed = ResponseInterpreter.interpret(
            data: Data("not-json".utf8),
            statusCode: 200,
            configuration: ResponseConfiguration()
        )
        XCTAssertEqual(malformed.confirmation, .unconfirmed)

        let rejectedData = try JSONSerialization.data(withJSONObject: ["success": false])
        let rejected = ResponseInterpreter.interpret(
            data: rejectedData,
            statusCode: 200,
            configuration: ResponseConfiguration()
        )
        XCTAssertEqual(rejected.confirmation, .applicationFailure)
    }

    func testInvalidImportDoesNotPartiallyChangeStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DestinationStore(rootURL: root)
        var invalid = DestinationProfile()
        invalid.version = 99
        invalid.endpointURL = "https://example.test/upload"
        let data = try JSONEncoder().encode(invalid)

        XCTAssertThrowsError(try store.importProfile(data))
        XCTAssertTrue(store.profiles.isEmpty)
    }
}
