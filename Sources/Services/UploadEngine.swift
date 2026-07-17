import Foundation

struct UploadEngine: Sendable {
    struct Context: Sendable {
        var batch: DraftBatch
        var outputs: [PreparedDocument]
        var profile: DestinationProfile
        var credential: String?
        var parameterValues: [ParameterValueKey: String]
    }

    func upload(
        context: Context,
        onProgress: @escaping @Sendable (Double) -> Void,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onDocumentActivity: @escaping @Sendable (UUID, DocumentUploadActivity) -> Void = { _, _ in },
        onDocumentResult: @escaping @Sendable (UploadDocumentResult) async throws -> Void = { _ in },
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void = { _ in },
        waitForConnectivity: @escaping @Sendable () async -> Bool = { false },
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool = { _ in false }
    ) async throws -> UploadBatchResult {
        switch context.profile.batchRequestMode {
        case .oneMultipartRequest:
            return try await uploadOneRequest(
                context: context,
                onProgress: onProgress,
                onRetry: onRetry,
                onDocumentActivity: onDocumentActivity,
                onDocumentResult: onDocumentResult,
                onAttempt: onAttempt,
                waitForConnectivity: waitForConnectivity,
                confirmLongRetry: confirmLongRetry
            )
        case .oneRequestPerDocument:
            return try await uploadPerDocument(
                context: context,
                onProgress: onProgress,
                onRetry: onRetry,
                onDocumentActivity: onDocumentActivity,
                onDocumentResult: onDocumentResult,
                onAttempt: onAttempt,
                waitForConnectivity: waitForConnectivity,
                confirmLongRetry: confirmLongRetry
            )
        }
    }

    private func uploadOneRequest(
        context: Context,
        onProgress: @escaping @Sendable (Double) -> Void,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onDocumentActivity: @escaping @Sendable (UUID, DocumentUploadActivity) -> Void,
        onDocumentResult: @escaping @Sendable (UploadDocumentResult) async throws -> Void,
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void,
        waitForConnectivity: @escaping @Sendable () async -> Bool,
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool
    ) async throws -> UploadBatchResult {
        let bodyDirectory = context.outputs[0].fileURL.deletingLastPathComponent()
        let response = try await perform(
            context: context,
            document: context.outputs.count == 1 ? context.outputs.first : nil,
            bodyDirectory: bodyDirectory,
            idempotencyValue: context.batch.logicalBatchID.uuidString,
            documentIDs: context.outputs.map(\.id),
            onProgress: { progress in
                onProgress(progress)
                for output in context.outputs { onDocumentActivity(output.id, .uploading(progress)) }
            },
            onRetry: { attempt, seconds in
                onRetry(attempt, seconds)
                for output in context.outputs {
                    onDocumentActivity(output.id, .waitingToRetry(attempt: attempt, seconds: seconds))
                }
            },
            onAttempt: onAttempt,
            waitForConnectivity: waitForConnectivity,
            confirmLongRetry: confirmLongRetry
        )
        let interpreted = ResponseInterpreter.interpret(
            data: response.data,
            statusCode: response.statusCode,
            contentType: response.contentType,
            validateContentType: true,
            configuration: context.profile.response
        )

        if context.outputs.count > 1,
           context.profile.response.mode != .statusOnly,
           interpreted.confirmation == .confirmed {
            let perDocument = parsePerDocumentResults(
                data: response.data,
                outputs: context.outputs,
                requestID: response.requestID,
                statusCode: response.statusCode,
                profile: context.profile,
                attemptCount: response.attemptCount
            )
            if !perDocument.isEmpty {
                for result in perDocument {
                    let activity: DocumentUploadActivity = result.confirmation == .confirmed
                        ? .confirmed
                        : .unconfirmed(result.message)
                    onDocumentActivity(
                        result.documentID,
                        activity
                    )
                    try await onDocumentResult(result)
                }
                return .init(documentResults: perDocument, message: interpreted.message)
            }
            let results: [UploadDocumentResult] = context.outputs.map {
                UploadDocumentResult(
                    documentID: $0.id,
                    confirmation: .unconfirmed,
                    requestID: response.requestID,
                    statusCode: response.statusCode,
                    message: String(localized: "The batch response did not identify each document. No result was assumed."),
                    attemptCount: response.attemptCount)
            }
            for result in results { onDocumentActivity(result.documentID, .unconfirmed(result.message)) }
            for result in results { try await onDocumentResult(result) }
            return .init(documentResults: results)
        }

        let results: [UploadDocumentResult] = context.outputs.map {
            UploadDocumentResult(
                documentID: $0.id,
                confirmation: interpreted.confirmation,
                requestID: response.requestID,
                statusCode: response.statusCode,
                message: interpreted.message,
                remoteID: context.outputs.count == 1 ? interpreted.remoteID : nil,
                openURL: context.outputs.count == 1 ? validatedOpenURL(interpreted.openURL, profile: context.profile) : nil,
                attemptCount: response.attemptCount
            )
        }
        for result in results {
            let activity: DocumentUploadActivity = result.confirmation == .confirmed
                ? .confirmed
                : .unconfirmed(result.message)
            onDocumentActivity(
                result.documentID,
                activity
            )
            try await onDocumentResult(result)
        }
        return .init(documentResults: results, message: interpreted.message)
    }

    private func uploadPerDocument(
        context: Context,
        onProgress: @escaping @Sendable (Double) -> Void,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onDocumentActivity: @escaping @Sendable (UUID, DocumentUploadActivity) -> Void,
        onDocumentResult: @escaping @Sendable (UploadDocumentResult) async throws -> Void,
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void,
        waitForConnectivity: @escaping @Sendable () async -> Bool,
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool
    ) async throws -> UploadBatchResult {
        let progress = PerDocumentProgress(count: context.outputs.count, callback: onProgress)
        let indexedResults: [(Int, UploadDocumentResult)]
        if context.profile.requestConcurrency == .twoAtATime {
            indexedResults = try await withThrowingTaskGroup(of: (Int, UploadDocumentResult).self) { group in
                var nextIndex = 0
                var completed: [(Int, UploadDocumentResult)] = []
                func addNext() {
                    guard nextIndex < context.outputs.count else { return }
                    let index = nextIndex
                    let output = context.outputs[index]
                    nextIndex += 1
                    group.addTask {
                        let result = try await uploadDocumentPreservingFailure(
                            context: context,
                            output: output,
                            index: index,
                            progress: progress,
                            onRetry: onRetry,
                            onDocumentActivity: onDocumentActivity,
                            onDocumentResult: onDocumentResult,
                            onAttempt: onAttempt,
                            waitForConnectivity: waitForConnectivity,
                            confirmLongRetry: confirmLongRetry
                        )
                        return (index, result)
                    }
                }
                addNext()
                addNext()
                while let value = try await group.next() {
                    completed.append(value)
                    addNext()
                }
                return completed
            }
        } else {
            var completed: [(Int, UploadDocumentResult)] = []
            for (index, output) in context.outputs.enumerated() {
                completed.append((index, try await uploadDocumentPreservingFailure(
                    context: context,
                    output: output,
                    index: index,
                    progress: progress,
                    onRetry: onRetry,
                    onDocumentActivity: onDocumentActivity,
                    onDocumentResult: onDocumentResult,
                    onAttempt: onAttempt,
                    waitForConnectivity: waitForConnectivity,
                    confirmLongRetry: confirmLongRetry
                )))
            }
            indexedResults = completed
        }
        let results = indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        return .init(documentResults: results, message: results.last?.message)
    }

    private func uploadDocumentPreservingFailure(
        context: Context,
        output: PreparedDocument,
        index: Int,
        progress: PerDocumentProgress,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onDocumentActivity: @escaping @Sendable (UUID, DocumentUploadActivity) -> Void,
        onDocumentResult: @escaping @Sendable (UploadDocumentResult) async throws -> Void,
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void,
        waitForConnectivity: @escaping @Sendable () async -> Bool,
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool
    ) async throws -> UploadDocumentResult {
        let result: UploadDocumentResult
        do {
            result = try await uploadDocument(
                context: context,
                output: output,
                index: index,
                progress: progress,
                onRetry: onRetry,
                onDocumentActivity: onDocumentActivity,
                onAttempt: onAttempt,
                waitForConnectivity: waitForConnectivity,
                confirmLongRetry: confirmLongRetry
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await progress.update(index: index, value: 1)
            let message = String(error.localizedDescription.prefix(500))
            onDocumentActivity(output.id, .failed(message))
            result = UploadDocumentResult(
                documentID: output.id,
                confirmation: .unconfirmed,
                requestID: nil,
                statusCode: nil,
                message: message,
                attemptCount: 0
            )
        }
        try await onDocumentResult(result)
        return result
    }

    private func uploadDocument(
        context: Context,
        output: PreparedDocument,
        index: Int,
        progress: PerDocumentProgress,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onDocumentActivity: @escaping @Sendable (UUID, DocumentUploadActivity) -> Void,
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void,
        waitForConnectivity: @escaping @Sendable () async -> Bool,
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool
    ) async throws -> UploadDocumentResult {
        try Task.checkCancellation()
        onDocumentActivity(output.id, .uploading(0))
        let response = try await perform(
            context: context,
            document: output,
            bodyDirectory: output.fileURL.deletingLastPathComponent(),
            idempotencyValue: output.id.uuidString,
            documentIDs: [output.id],
            onProgress: { documentProgress in
                Task { await progress.update(index: index, value: documentProgress) }
                onDocumentActivity(output.id, .uploading(documentProgress))
            },
            onRetry: { attempt, seconds in
                onRetry(attempt, seconds)
                onDocumentActivity(output.id, .waitingToRetry(attempt: attempt, seconds: seconds))
            },
            onAttempt: onAttempt,
            waitForConnectivity: waitForConnectivity,
            confirmLongRetry: confirmLongRetry
        )
        let interpreted = ResponseInterpreter.interpret(
            data: response.data,
            statusCode: response.statusCode,
            contentType: response.contentType,
            validateContentType: true,
            configuration: context.profile.response
        )
        await progress.update(index: index, value: 1)
        let result = UploadDocumentResult(
            documentID: output.id,
            confirmation: interpreted.confirmation,
            requestID: response.requestID,
            statusCode: response.statusCode,
            message: interpreted.message,
            remoteID: interpreted.remoteID,
            openURL: validatedOpenURL(interpreted.openURL, profile: context.profile),
            attemptCount: response.attemptCount
        )
        let activity: DocumentUploadActivity = result.confirmation == .confirmed
            ? .confirmed
            : .unconfirmed(result.message)
        onDocumentActivity(output.id, activity)
        return result
    }

    private func perform(
        context: Context,
        document: PreparedDocument?,
        bodyDirectory: URL,
        idempotencyValue: String,
        documentIDs: [UUID],
        onProgress: @escaping @Sendable (Double) -> Void,
        onRetry: @escaping @Sendable (Int, Int) -> Void,
        onAttempt: @escaping @Sendable (UploadAttemptEvent) async -> Void,
        waitForConnectivity: @escaping @Sendable () async -> Bool,
        confirmLongRetry: @escaping @Sendable (Int) async -> Bool
    ) async throws -> PerformResponse {
        let profile = context.profile
        let delays = [2, 10, 30]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let attemptNumber = attempt + 1
            let attemptRequestID = UUID()
            let attemptedAt = Date()
            do {
                let body = try MultipartBodyBuilder.build(
                    parts: multipartParts(
                        context: context,
                        document: document,
                        requestID: attemptRequestID
                    ),
                    in: bodyDirectory
                )
                defer { try? FileManager.default.removeItem(at: body.url) }
                var request = try makeRequest(
                    context: context,
                    document: document,
                    requestID: attemptRequestID,
                    body: body
                )
                request.setValue(idempotencyValue, forHTTPHeaderField: profile.idempotencyHeaderName)
                request.setValue(attemptRequestID.uuidString, forHTTPHeaderField: "X-Request-ID")
                let delegate = BoundedUploadDelegate(
                    originalHost: URL(string: profile.endpointURL)?.host?.lowercased() ?? "",
                    allowedHosts: Set(profile.allowedRedirectHosts.map { $0.lowercased() }),
                    sensitiveHeaderNames: sensitiveHeaderNames(for: profile),
                    maximumResponseBytes: profile.response.maximumBodyBytes,
                    progress: onProgress
                )
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = profile.requestTimeout
                configuration.timeoutIntervalForResource = profile.requestTimeout
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let (data, http) = try await delegate.upload(using: session, request: request, fromFile: body.url)
                await onAttempt(.init(
                    requestID: attemptRequestID,
                    documentIDs: documentIDs,
                    attemptNumber: attemptNumber,
                    attemptedAt: attemptedAt,
                    statusCode: http.statusCode,
                    outcome: "http_\(http.statusCode)"
                ))
                if UploadRetryPolicy.shouldRetry(statusCode: http.statusCode), profile.receiverSupportsIdempotency, attempt < delays.count {
                    switch UploadRetryPolicy.retryDecision(response: http, fallback: delays[attempt]) {
                    case let .automatic(seconds):
                        attempt += 1
                        onRetry(attempt, seconds)
                        try await Task.sleep(for: .seconds(seconds))
                    case let .manualConfirmation(seconds):
                        attempt += 1
                        onRetry(attempt, seconds)
                        guard await confirmLongRetry(seconds) else {
                            throw UploadEngineError.longRetryDeclined
                        }
                        try Task.checkCancellation()
                        try await Task.sleep(for: .seconds(seconds))
                    }
                    continue
                }
                if profile.receiverSupportsIdempotency,
                   attempt < delays.count,
                   responseRequiresIdempotentRetry(
                       data: data,
                       statusCode: http.statusCode,
                       contentType: http.value(forHTTPHeaderField: "Content-Type"),
                       context: context,
                       documentIDs: documentIDs
                   ) {
                    let delay = delays[attempt]
                    attempt += 1
                    onRetry(attempt, delay)
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                return PerformResponse(
                    data: data,
                    statusCode: http.statusCode,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    requestID: attemptRequestID,
                    attemptCount: attemptNumber
                )
            } catch is CancellationError {
                await onAttempt(.init(
                    requestID: attemptRequestID,
                    documentIDs: documentIDs,
                    attemptNumber: attemptNumber,
                    attemptedAt: attemptedAt,
                    statusCode: nil,
                    outcome: "cancelled"
                ))
                throw CancellationError()
            } catch let error as UploadEngineError {
                await onAttempt(.init(
                    requestID: attemptRequestID,
                    documentIDs: documentIDs,
                    attemptNumber: attemptNumber,
                    attemptedAt: attemptedAt,
                    statusCode: nil,
                    outcome: sanitizedOutcome(for: error)
                ))
                throw error
            } catch {
                await onAttempt(.init(
                    requestID: attemptRequestID,
                    documentIDs: documentIDs,
                    attemptNumber: attemptNumber,
                    attemptedAt: attemptedAt,
                    statusCode: nil,
                    outcome: sanitizedOutcome(for: error)
                ))
                if profile.receiverSupportsIdempotency,
                   UploadRetryPolicy.isRetryable(error),
                   await waitForConnectivity() {
                    continue
                }
                guard UploadRetryPolicy.isRetryable(error), profile.receiverSupportsIdempotency, attempt < delays.count else { throw error }
                let delay = delays[attempt]
                attempt += 1
                onRetry(attempt, delay)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func sensitiveHeaderNames(for profile: DestinationProfile) -> Set<String> {
        var names = profile.parameters
            .filter { $0.enabled && $0.location == .header && $0.sensitive }
            .map(\.name)
        if profile.authentication.kind != .none { names.append(profile.authentication.headerName) }
        return Set(names)
    }

    func responseRequiresIdempotentRetry(
        data: Data,
        statusCode: Int,
        contentType: String?,
        context: Context,
        documentIDs: [UUID]
    ) -> Bool {
        let profile = context.profile
        guard profile.response.successStatuses.contains(statusCode) else { return false }
        let interpreted = ResponseInterpreter.interpret(
            data: data,
            statusCode: statusCode,
            contentType: contentType,
            validateContentType: true,
            configuration: profile.response
        )
        if interpreted.confirmation == .unconfirmed { return true }
        guard interpreted.confirmation == .confirmed,
              documentIDs.count > 1,
              profile.response.mode != .statusOnly else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rows = ResponseInterpreter.value(
                  at: profile.response.custom.documentsPath,
                  in: object
              ) as? [[String: Any]] else { return true }
        return documentIDs.contains { documentID in
            !rows.contains { row in
                row[profile.response.custom.documentIdentifierPath] as? String == documentID.uuidString
                    && row["success"] is Bool
            }
        }
    }

    func makeRequest(
        context: Context,
        document: PreparedDocument?,
        requestID: UUID,
        body: MultipartBody
    ) throws -> URLRequest {
        let profile = context.profile
        let templateParameterValues = Dictionary(uniqueKeysWithValues: profile.parameters
            .filter { $0.enabled && !$0.sensitive }
            .compactMap { parameter in
                resolvedValue(parameter, context: context, document: document, requestID: requestID)
                    .map { (parameter.name, $0) }
            })
        let endpoint = try DestinationURLTemplate.resolve(
            profile.endpointURL,
            batchID: context.batch.logicalBatchID,
            documentID: document?.id,
            requestID: requestID,
            parameterValues: templateParameterValues
        )
        guard var components = URLComponents(string: endpoint) else { throw UploadEngineError.invalidURL }
        let queryItems = profile.parameters
            .filter { $0.enabled && $0.location == .query && !$0.sensitive }
            .compactMap { parameter -> URLQueryItem? in
                guard let value = resolvedValue(
                    parameter,
                    context: context,
                    document: document,
                    requestID: requestID
                ) else { return nil }
                return URLQueryItem(name: parameter.name, value: value)
            }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let url = components.url, DestinationValidator.isAllowedTransportURL(url) else {
            throw UploadEngineError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = profile.method.rawValue
        request.timeoutInterval = profile.requestTimeout
        request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
        for parameter in profile.parameters where parameter.enabled && parameter.location == .header {
            if let value = resolvedValue(parameter, context: context, document: document, requestID: requestID) {
                request.setValue(value, forHTTPHeaderField: parameter.name)
            }
        }
        if let credential = context.credential, !credential.isEmpty {
            switch profile.authentication.kind {
            case .none: break
            case .bearerToken: request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            case .customHeader: request.setValue(credential, forHTTPHeaderField: profile.authentication.headerName)
            }
        }
        return request
    }

    func multipartParts(context: Context, document: PreparedDocument?, requestID: UUID) -> [MultipartPart] {
        let outputs = document.map { [$0] } ?? context.outputs
        var parts: [MultipartPart] = outputs.enumerated().map { localIndex, output in
            let documentIndex = context.outputs.firstIndex(where: { $0.id == output.id }) ?? localIndex
            let name = MultipartFileFieldName.resolve(
                profile: context.profile,
                index: documentIndex,
                documentID: output.id
            )
            return .file(name: name, filename: output.filename, contentType: output.contentType, url: output.fileURL)
        }
        parts.append(.field(name: "batch_id", value: context.batch.logicalBatchID.uuidString))
        parts.append(.field(name: "request_id", value: requestID.uuidString))
        if let document {
            parts.append(.field(name: "document_id", value: document.id.uuidString))
            parts.append(.field(name: "page_count", value: String(document.pageCount)))
            if let index = context.outputs.firstIndex(where: { $0.id == document.id }) {
                parts.append(.field(name: "document_index", value: String(index)))
            }
        } else if context.outputs.count == 1, let output = context.outputs.first {
            parts.append(.field(name: "document_id", value: output.id.uuidString))
            parts.append(.field(name: "page_count", value: String(output.pageCount)))
        }
        if context.profile.includeBatchManifest && document == nil {
            parts.append(.field(
                name: context.profile.manifestFieldName,
                value: manifest(context: context, requestID: requestID)
            ))
        }
        let parameterDocument = document ?? (context.outputs.count == 1 ? context.outputs.first : nil)
        for parameter in context.profile.parameters where parameter.enabled && parameter.location == .form {
            guard parameter.scope != .document || parameterDocument != nil else { continue }
            let value = resolvedValue(parameter, context: context, document: parameterDocument, requestID: requestID)
            if let value { parts.append(.field(name: parameter.name, value: value)) }
        }
        return parts
    }

    private func resolvedValue(
        _ parameter: DestinationParameter,
        context: Context,
        document: PreparedDocument?,
        requestID: UUID
    ) -> String? {
        if let value = context.parameterValues[
            ParameterValueKey(parameterID: parameter.id, documentID: parameter.scope == .document ? document?.id : nil)
        ] ?? context.parameterValues[ParameterValueKey(parameterID: parameter.id, documentID: nil)] {
            return value
        }
        if parameter.sensitive { return nil }
        switch parameter.valueSource {
        case .fixed: return parameter.value
        case .userEntered:
            if parameter.scope == .document, let document {
                return context.batch.documents.first(where: { $0.id == document.id })?.metadata[parameter.name]
                    ?? parameter.defaultValue
            }
            return context.batch.metadata[parameter.name] ?? parameter.defaultValue
        case .generated: return UUID().uuidString
        case .builtIn:
            switch parameter.builtInValue {
            case .documentID: return document?.id.uuidString
            case .batchID: return context.batch.logicalBatchID.uuidString
            case .filename: return document?.filename
            case .pageCount: return document.map { String($0.pageCount) }
            case .documentCount: return String(context.outputs.count)
            case .scannedAt: return ISO8601DateFormatter().string(from: context.batch.createdAt)
            case .scannerName:
                return context.batch.documents.first(where: { $0.id == document?.id })?.scanSettings.scannerName
                    ?? context.batch.documents.first?.scanSettings.scannerName
            case .contentType: return document?.contentType
            case .requestID: return requestID.uuidString
            case .none: return nil
            }
        }
    }

    private func manifest(context: Context, requestID: UUID) -> String {
        let documents: [[String: Any]] = context.outputs.map { output in
            let source = context.batch.documents.first { $0.id == output.id }
            var row: [String: Any] = [
                "document_id": output.id.uuidString,
                "filename": output.filename,
                "page_count": output.pageCount,
                "scanned_at": ISO8601DateFormatter().string(from: source?.createdAt ?? context.batch.createdAt)
            ]
            for parameter in context.profile.parameters
            where parameter.enabled && parameter.scope == .document {
                if let value = resolvedValue(
                    parameter,
                    context: context,
                    document: output,
                    requestID: requestID
                ) {
                    row[parameter.name] = value
                }
            }
            return row
        }
        let object: [String: Any] = ["batch_id": context.batch.logicalBatchID.uuidString, "documents": documents]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func parsePerDocumentResults(
        data: Data,
        outputs: [PreparedDocument],
        requestID: UUID,
        statusCode: Int,
        profile: DestinationProfile,
        attemptCount: Int
    ) -> [UploadDocumentResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rows = ResponseInterpreter.value(at: profile.response.custom.documentsPath, in: object) as? [[String: Any]] else {
            return []
        }
        return outputs.map { output in
            guard let row = rows.first(where: {
                ($0[profile.response.custom.documentIdentifierPath] as? String) == output.id.uuidString
            }), let success = row["success"] as? Bool else {
                return UploadDocumentResult(
                    documentID: output.id,
                    confirmation: .unconfirmed,
                    requestID: requestID,
                    statusCode: statusCode,
                    message: String(localized: "The batch response did not include a valid result for this document."),
                    attemptCount: attemptCount
                )
            }
            return .init(
                documentID: output.id,
                confirmation: success ? .confirmed : .applicationFailure,
                requestID: requestID,
                statusCode: statusCode,
                message: ResponseInterpreter.sanitize(row["message"] as? String),
                remoteID: ResponseInterpreter.sanitize(row["id"] as? String),
                attemptCount: attemptCount
            )
        }
    }

    private func sanitizedOutcome(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "network_\(urlError.code.rawValue)" }
        if let uploadError = error as? UploadEngineError {
            if case .responseTooLarge = uploadError { return "response_too_large" }
            return "protocol_error"
        }
        return "unknown_error"
    }

    private func validatedOpenURL(_ url: URL?, profile: DestinationProfile) -> URL? {
        guard let url, DestinationValidator.isAllowedTransportURL(url), let host = url.host?.lowercased() else { return nil }
        let allowed = Set([profile.host].compactMap { $0 } + profile.allowedRedirectHosts.map { $0.lowercased() })
        return allowed.contains(host) ? url : nil
    }
}

enum MultipartFileFieldName {
    private static let fallbackPattern = "file-{index}"
    private static let allowedPlaceholders: Set<String> = ["{index}", "{document_id}", "{file_field}"]

    static func resolve(profile: DestinationProfile, index: Int, documentID: UUID) -> String {
        switch profile.fileFieldConvention {
        case .repeated:
            return profile.fileFieldName
        case .indexed:
            return "\(profile.fileFieldName)[\(index)]"
        case .customPerDocument:
            return (profile.customFileFieldPattern ?? fallbackPattern)
                .replacingOccurrences(of: "{index}", with: String(index))
                .replacingOccurrences(of: "{document_id}", with: documentID.uuidString)
                .replacingOccurrences(of: "{file_field}", with: profile.fileFieldName)
        }
    }

    static func validationIssue(for profile: DestinationProfile) -> String? {
        let pattern = profile.customFileFieldPattern ?? fallbackPattern
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Enter a custom multipart file field pattern.")
        }
        let placeholders = pattern.matches(of: /\{[^}]+\}/).map { String($0.output) }
        if placeholders.contains(where: { !allowedPlaceholders.contains($0) }) {
            return String(localized: "The file field pattern contains an unsupported placeholder.")
        }
        if !pattern.contains("{index}") && !pattern.contains("{document_id}") {
            return String(localized: "A custom file field pattern must identify each document with {index} or {document_id}.")
        }
        let sample = pattern
            .replacingOccurrences(of: "{index}", with: "0")
            .replacingOccurrences(of: "{document_id}", with: UUID().uuidString)
            .replacingOccurrences(of: "{file_field}", with: profile.fileFieldName)
        return DestinationValidator.validFieldName(sample)
            ? nil
            : String(localized: "The custom multipart file field pattern is invalid.")
    }
}

private actor PerDocumentProgress {
    private var values: [Int: Double] = [:]
    private let count: Int
    private let callback: @Sendable (Double) -> Void

    init(count: Int, callback: @escaping @Sendable (Double) -> Void) {
        self.count = max(count, 1)
        self.callback = callback
    }

    func update(index: Int, value: Double) {
        values[index] = min(max(value, 0), 1)
        callback(values.values.reduce(0, +) / Double(count))
    }
}

enum UploadRetryPolicy {
    enum Decision: Equatable {
        case automatic(Int)
        case manualConfirmation(Int)
    }

    static func shouldRetry(statusCode: Int) -> Bool {
        [408, 425, 429].contains(statusCode) || (500...599).contains(statusCode)
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
            .callIsActive, .dataNotAllowed, .resourceUnavailable
        ].contains(urlError.code)
    }

    static func retryDecision(
        response: HTTPURLResponse,
        fallback: Int,
        now: Date = Date()
    ) -> Decision {
        guard let seconds = retryAfterSeconds(response: response, now: now) else {
            return .automatic(fallback)
        }
        return seconds <= 300 ? .automatic(seconds) : .manualConfirmation(seconds)
    }

    private static func retryAfterSeconds(response: HTTPURLResponse, now: Date) -> Int? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        if let seconds = Int(rawValue), seconds >= 0 { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                return max(0, Int(ceil(date.timeIntervalSince(now))))
            }
        }
        return nil
    }
}

private struct PerformResponse: Sendable {
    var data: Data
    var statusCode: Int
    var contentType: String?
    var requestID: UUID
    var attemptCount: Int
}

enum UploadEngineError: LocalizedError {
    case invalidURL
    case nonHTTPResponse
    case responseTooLarge(Int)
    case destinationConstraint(String)
    case outputSizeExceeded(String)
    case longRetryDeclined

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "The destination URL is invalid or uses HTTP outside the local network.")
        case .nonHTTPResponse: String(localized: "The destination did not return an HTTP response.")
        case let .responseTooLarge(maximum): String(localized: "The destination response exceeded the configured \(maximum)-byte limit.")
        case let .destinationConstraint(message): message
        case let .outputSizeExceeded(message): message
        case .longRetryDeclined:
            String(localized: "The server requested a long retry delay, and the retry was not approved.")
        }
    }
}
