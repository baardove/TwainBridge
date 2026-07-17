import CoreGraphics
import Foundation

struct DestinationConnectionTester: Sendable {
    func test(
        profile: DestinationProfile,
        credential: String?,
        parameterSecrets: [UUID: String] = [:]
    ) async -> ConnectionTestResult {
        let issues = DestinationValidator.validate(
            profile,
            hasAuthenticationSecret: profile.authentication.kind == .none || credential?.isEmpty == false
        )
        if let error = issues.first(where: { $0.severity == .error }) {
            return .init(outcome: .invalidResponse, summary: error.message)
        }

        let fixtureDocumentID = UUID()
        let fixtureBatchID = UUID()
        let fixtureRequestID = UUID()
        let resolvedValues = Dictionary(uniqueKeysWithValues: profile.parameters.filter(\.enabled).compactMap { parameter in
            testValue(
                for: parameter,
                secrets: parameterSecrets,
                documentID: fixtureDocumentID,
                batchID: fixtureBatchID,
                requestID: fixtureRequestID
            ).map { (parameter.id, $0) }
        })
        if let invalid = profile.parameters.filter(\.enabled).compactMap({ parameter in
            DestinationParameterValidator.validate(value: resolvedValues[parameter.id], for: parameter)
        }).first {
            return .init(outcome: .invalidResponse, summary: invalid)
        }

        let templateValues = Dictionary(uniqueKeysWithValues: profile.parameters.filter(\.enabled).compactMap { parameter in
            resolvedValues[parameter.id].map { value in (parameter.name, value) }
        })
        guard let endpointString = try? DestinationURLTemplate.resolve(
            profile.endpointURL,
            batchID: fixtureBatchID,
            documentID: fixtureDocumentID,
            requestID: fixtureRequestID,
            parameterValues: templateValues
        ),
              var components = URLComponents(string: endpointString),
              let endpoint = components.url,
              let originalHost = endpoint.host?.lowercased() else {
            return .init(outcome: .invalidResponse, summary: String(localized: "The destination URL is invalid."))
        }

        let queryParameters = profile.parameters.filter { $0.enabled && $0.location == .query && !$0.sensitive }
        if !queryParameters.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: queryParameters.compactMap { parameter in
                resolvedValues[parameter.id].map { URLQueryItem(name: parameter.name, value: $0) }
            })
            components.queryItems = items
        }
        guard let finalURL = components.url else {
            return .init(outcome: .invalidResponse, summary: String(localized: "The destination query parameters are invalid."))
        }

        let boundary = "TwainBridge-Test-\(UUID().uuidString)"
        var request = URLRequest(url: finalURL)
        request.httpMethod = profile.method.rawValue
        request.timeoutInterval = profile.requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("TwainBridge connection test", forHTTPHeaderField: "X-TwainBridge-Test")

        for parameter in profile.parameters where parameter.enabled && parameter.location == .header {
            if let value = resolvedValues[parameter.id] {
                request.setValue(value, forHTTPHeaderField: parameter.name)
            }
        }
        applyAuthentication(profile.authentication, credential: credential, to: &request)

        var body = Data()
        for parameter in profile.parameters where parameter.enabled && parameter.location == .form {
            if let value = resolvedValues[parameter.id] {
                body.appendMultipartField(name: parameter.name, value: value, boundary: boundary)
            }
        }
        guard let pdf = Self.generatedTestPDFData() else {
            return .init(outcome: .invalidResponse, summary: String(localized: "The generated test PDF could not be created."))
        }
        let fieldName = MultipartFileFieldName.resolve(
            profile: profile,
            index: 0,
            documentID: fixtureDocumentID
        )
        body.appendMultipartFile(
            name: fieldName,
            filename: "twainbridge-test.pdf",
            contentType: "application/pdf",
            data: pdf,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = profile.requestTimeout
        configuration.timeoutIntervalForResource = profile.requestTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let redirectDelegate = BoundedUploadDelegate(
            originalHost: originalHost,
            allowedHosts: Set(profile.allowedRedirectHosts.map { $0.lowercased() }),
            sensitiveHeaderNames: Set(profile.parameters
                .filter { $0.enabled && $0.location == .header && $0.sensitive }
                .map(\.name) + (profile.authentication.kind == .none ? [] : [profile.authentication.headerName])),
            maximumResponseBytes: profile.response.maximumBodyBytes,
            progress: { _ in }
        )
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, http) = try await redirectDelegate.data(using: session, request: request)
            if http.statusCode == 401 || http.statusCode == 403 {
                return .init(
                    outcome: .authenticationFailure,
                    statusCode: http.statusCode,
                    summary: String(localized: "Authentication failed with HTTP \(http.statusCode).")
                )
            }
            if http.statusCode >= 500 {
                return .init(
                    outcome: .serverFailure,
                    statusCode: http.statusCode,
                    summary: String(localized: "The server returned HTTP \(http.statusCode).")
                )
            }
            let interpreted = ResponseInterpreter.interpret(
                data: data,
                statusCode: http.statusCode,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                validateContentType: true,
                configuration: profile.response
            )
            switch interpreted.confirmation {
            case .confirmed:
                return .init(
                    outcome: .success,
                    statusCode: http.statusCode,
                    summary: interpreted.message ?? String(localized: "Connection succeeded.")
                )
            case .applicationFailure, .unconfirmed:
                return .init(
                    outcome: .invalidResponse,
                    statusCode: http.statusCode,
                    summary: interpreted.message ?? String(localized: "The response could not be confirmed.")
                )
            }
        } catch let error as UploadEngineError {
            return .init(outcome: .invalidResponse, summary: error.localizedDescription)
        } catch let error as URLError {
            let tlsCodes: Set<URLError.Code> = [
                .secureConnectionFailed, .serverCertificateHasBadDate,
                .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected
            ]
            return .init(
                outcome: tlsCodes.contains(error.code) ? .tlsFailure : .unreachable,
                summary: tlsCodes.contains(error.code)
                    ? String(localized: "TLS validation failed. The certificate was not bypassed.")
                    : String(localized: "The destination could not be reached: \(error.localizedDescription)")
            )
        } catch {
            return .init(outcome: .unreachable, summary: String(localized: "The destination could not be reached: \(error.localizedDescription)"))
        }
    }

    private func applyAuthentication(
        _ authentication: AuthenticationConfiguration,
        credential: String?,
        to request: inout URLRequest
    ) {
        guard let credential, !credential.isEmpty else { return }
        switch authentication.kind {
        case .none: break
        case .bearerToken: request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        case .customHeader: request.setValue(credential, forHTTPHeaderField: authentication.headerName)
        }
    }

    static func generatedTestPDFData() -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return nil }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func testValue(
        for parameter: DestinationParameter,
        secrets: [UUID: String],
        documentID: UUID,
        batchID: UUID,
        requestID: UUID
    ) -> String? {
        if parameter.sensitive { return secrets[parameter.id] }
        switch parameter.valueSource {
        case .fixed: return parameter.value ?? parameter.defaultValue
        case .userEntered: return parameter.defaultValue
        case .generated: return UUID().uuidString
        case .builtIn:
            switch parameter.builtInValue {
            case .documentID: return documentID.uuidString
            case .batchID: return batchID.uuidString
            case .filename: return "twainbridge-test.pdf"
            case .pageCount, .documentCount: return "1"
            case .scannedAt: return ISO8601DateFormatter().string(from: Date())
            case .scannerName: return "TwainBridge Test"
            case .contentType: return "application/pdf"
            case .requestID: return requestID.uuidString
            case .none: return nil
            }
        }
    }
}

final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let originalHost: String
    private let allowedHosts: Set<String>
    private let sensitiveHeaderNames: Set<String>
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var redirectCount = 0

    init(
        originalHost: String,
        allowedHosts: Set<String>,
        sensitiveHeaderNames: Set<String>,
        progress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.originalHost = originalHost
        self.allowedHosts = allowedHosts
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        guard count <= 5,
              request.url.map(DestinationValidator.isAllowedTransportURL) == true,
              let newHost = request.url?.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        let sameHost = newHost == originalHost
        guard sameHost || allowedHosts.contains(newHost) else {
            completionHandler(nil)
            return
        }
        var sanitized = request
        if !sameHost {
            for header in request.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys
            where sensitiveHeaderNames.contains(header.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: header)
            }
        }
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1))
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data(value.utf8))
        append(Data("\r\n".utf8))
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
