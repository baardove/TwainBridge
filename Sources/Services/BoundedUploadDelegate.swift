import Foundation

struct BoundedResponseBuffer: Sendable {
    let maximumByteCount: Int
    private(set) var data = Data()

    init(maximumByteCount: Int) {
        self.maximumByteCount = max(maximumByteCount, 0)
    }

    mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maximumByteCount - data.count else {
            throw UploadEngineError.responseTooLarge(maximumByteCount)
        }
        data.append(chunk)
    }
}

/// Receives upload responses incrementally so a receiver cannot make the app
/// buffer an arbitrarily large body before the configured limit is enforced.
final class BoundedUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let originalHost: String
    private let allowedHosts: Set<String>
    private let sensitiveHeaderNames: Set<String>
    private let progress: @Sendable (Double) -> Void
    private let maximumResponseBytes: Int
    private let lock = NSLock()

    private var redirectCount = 0
    private var buffer: BoundedResponseBuffer
    private var response: HTTPURLResponse?
    private var terminalError: Error?
    private var activeTask: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(
        originalHost: String,
        allowedHosts: Set<String>,
        sensitiveHeaderNames: Set<String>,
        maximumResponseBytes: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.originalHost = originalHost
        self.allowedHosts = allowedHosts
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.maximumResponseBytes = max(maximumResponseBytes, 0)
        self.buffer = BoundedResponseBuffer(maximumByteCount: maximumResponseBytes)
        self.progress = progress
    }

    func upload(
        using session: URLSession,
        request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        return try await run(task)
    }

    func data(using session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run(session.dataTask(with: request))
    }

    private func run(_ task: URLSessionTask) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                activeTask = task
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            self.cancelActiveTask()
        }
    }

    private func cancelActiveTask() {
        lock.lock()
        let task = activeTask
        lock.unlock()
        task?.cancel()
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
        progress(min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.lock()
            terminalError = UploadEngineError.nonHTTPResponse
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            lock.lock()
            terminalError = UploadEngineError.responseTooLarge(maximumResponseBytes)
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        lock.lock()
        do {
            try buffer.append(data)
        } catch {
            terminalError = error
            shouldCancel = true
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        activeTask = nil
        let terminalError = self.terminalError
        let response = self.response
        let data = buffer.data
        lock.unlock()

        guard let continuation else { return }
        if let terminalError {
            continuation.resume(throwing: terminalError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (data, response))
        } else {
            continuation.resume(throwing: UploadEngineError.nonHTTPResponse)
        }
    }
}
