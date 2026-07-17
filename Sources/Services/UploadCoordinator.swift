import AppKit
import Foundation

@MainActor
final class UploadCoordinator: ObservableObject {
    @Published private(set) var activity: UploadActivity = .idle
    @Published private(set) var activeBatchID: UUID?
    @Published private(set) var lastResult: UploadBatchResult?
    @Published private(set) var documentActivities: [UUID: DocumentUploadActivity] = [:]
    @Published private(set) var pendingOpenURL: URL?
    @Published private(set) var pendingRetryConfirmation: LongRetryPrompt?

    private let draftStore: DraftStore
    private let destinationStore: DestinationStore
    private let historyStore: TransferHistoryStore
    private let networkMonitor: NetworkMonitor
    private let notificationService: NotificationService
    private var activeTask: Task<Void, Never>?
    private var cancellationIsForTermination = false
    private var activeRetryDecision: PendingRetryDecision?
    private var queuedRetryDecisions: [PendingRetryDecision] = []

    private struct PendingRetryDecision {
        var prompt: LongRetryPrompt
        var continuation: CheckedContinuation<Bool, Never>
    }

    init(
        draftStore: DraftStore,
        destinationStore: DestinationStore,
        historyStore: TransferHistoryStore,
        networkMonitor: NetworkMonitor,
        notificationService: NotificationService
    ) {
        self.draftStore = draftStore
        self.destinationStore = destinationStore
        self.historyStore = historyStore
        self.networkMonitor = networkMonitor
        self.notificationService = notificationService
    }

    func startSend(
        batchID: UUID,
        destinationID: UUID,
        ephemeralParameterSecrets: [ParameterValueKey: String] = [:]
    ) {
        guard activeTask == nil else { return }
        activeBatchID = batchID
        lastResult = nil
        pendingOpenURL = nil
        documentActivities = Dictionary(
            uniqueKeysWithValues: (draftStore.batches.first(where: { $0.id == batchID })?.documents ?? [])
                .filter { !$0.transfer.confirmed }
                .map { ($0.id, .queued) }
        )
        activeTask = Task { [weak self] in
            await self?.run(
                batchID: batchID,
                destinationID: destinationID,
                ephemeralParameterSecrets: ephemeralParameterSecrets
            )
        }
    }

    func cancel() {
        activeTask?.cancel()
        resolveAllRetryDecisions(approved: false)
    }

    func cancelForTermination() {
        cancellationIsForTermination = true
        activeTask?.cancel()
        resolveAllRetryDecisions(approved: false)
    }

    private func run(
        batchID: UUID,
        destinationID: UUID,
        ephemeralParameterSecrets: [ParameterValueKey: String]
    ) async {
        var outputs: [PreparedDocument] = []
        var historyBatch: DraftBatch?
        var historyProfile: DestinationProfile?
        defer {
            resolveAllRetryDecisions(approved: false)
            activeTask = nil
            activeBatchID = nil
            cancellationIsForTermination = false
        }
        do {
            guard let batch = draftStore.batches.first(where: { $0.id == batchID }) else {
                throw DraftStoreError.draftNotFound
            }
            guard let profile = destinationStore.profile(id: destinationID) else {
                throw DestinationStoreError.profileNotFound
            }
            historyBatch = batch
            historyProfile = profile
            let issues = destinationStore.validationIssues(for: profile)
            if let issue = issues.first(where: { $0.severity == .error }) {
                throw UploadEngineError.destinationConstraint(issue.message)
            }
            guard profile.enabled else {
                throw UploadEngineError.destinationConstraint(String(localized: "Enable this destination before sending documents."))
            }
            var parameterValues = Dictionary(uniqueKeysWithValues: profile.parameters.filter(\.sensitive).compactMap { parameter in
                let value: String? = if parameter.valueSource == .userEntered && parameter.rememberValue {
                    destinationStore.rememberedParameterValue(
                        profileID: profile.id,
                        parameterID: parameter.id
                    )
                } else {
                    destinationStore.parameterSecret(profileID: profile.id, parameterID: parameter.id)
                }
                return value.map { (ParameterValueKey(parameterID: parameter.id, documentID: nil), $0) }
            })
            parameterValues.merge(ephemeralParameterSecrets) { _, ephemeral in ephemeral }
            try validate(batch: batch, profile: profile)
            try validateParameters(batch: batch, profile: profile, values: parameterValues)
            let previousHost = batch.destinationID.flatMap { destinationStore.profile(id: $0)?.host }
            let hostChanged = previousHost != nil && previousHost != profile.host
            try await draftStore.assignDestination(
                destinationID,
                batchID: batchID,
                resetLogicalBatchID: hostChanged
            )
            guard let assignedBatch = draftStore.batches.first(where: { $0.id == batchID }) else {
                throw DraftStoreError.draftNotFound
            }
            if !networkMonitor.isOnline {
                try await draftStore.setBatchState(.waitingForNetwork, batchID: batchID)
                activity = .waitingForNetwork
                await networkMonitor.waitUntilOnline()
                try Task.checkCancellation()
            }
            try await draftStore.setBatchState(.preparing, batchID: batchID)
            activity = .preparing
            outputs = try await draftStore.prepareOutputs(
                batchID: batchID,
                filenamePattern: profile.filenamePattern
            )
            try validate(outputs: outputs, profile: profile)
            try Task.checkCancellation()
            try await draftStore.setBatchState(.uploading, batchID: batchID)
            activity = .uploading(progress: 0)

            let context = UploadEngine.Context(
                batch: assignedBatch,
                outputs: outputs,
                profile: profile,
                credential: destinationStore.credential(for: profile.id),
                parameterValues: parameterValues
            )
            let result = try await UploadEngine().upload(
                context: context,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.activity = .uploading(progress: progress) }
                },
                onRetry: { [weak self] attempt, seconds in
                    Task { @MainActor in self?.activity = .waitingToRetry(attempt: attempt, seconds: seconds) }
                },
                onDocumentActivity: { [weak self] documentID, documentActivity in
                    Task { @MainActor in self?.documentActivities[documentID] = documentActivity }
                },
                onDocumentResult: { [weak self] documentResult in
                    guard let self else { return }
                    try await self.draftStore.recordUploadResult(documentResult, batchID: batchID)
                },
                onAttempt: { [weak self] event in
                    guard let self else { return }
                    try? await self.draftStore.recordUploadAttempt(event, batchID: batchID)
                },
                waitForConnectivity: { [weak self] in
                    guard let self else { return false }
                    return await self.waitForNetworkIfNeeded(batchID: batchID)
                },
                confirmLongRetry: { [weak self] seconds in
                    guard let self else { return false }
                    return await self.requestLongRetryConfirmation(seconds: seconds)
                }
            )
            lastResult = result
            let confirmed = result.documentResults.filter { $0.confirmation == .confirmed }.count
            let historyResult: TransferHistoryResult
            if confirmed == result.documentResults.count {
                try await draftStore.setBatchState(.sent, batchID: batchID)
                activity = .completed(result.message ?? String(localized: "Upload confirmed."))
                historyResult = .sent
                notificationService.notify(title: String(localized: "Upload complete"), body: String(localized: "The document transfer was confirmed."))
                scheduleSentPayloadCleanup()
            } else if confirmed > 0 {
                if profile.partialSuccessBehavior == .keepFailedOnly {
                    try await draftStore.removeConfirmedDocuments(batchID: batchID)
                }
                try await draftStore.setBatchState(.partiallySent, batchID: batchID, errorCategory: "partial_success")
                activity = .failed(String(localized: "Some documents were sent; the remaining documents are still available."))
                historyResult = .partiallySent
                notificationService.notify(title: String(localized: "Upload needs attention"), body: String(localized: "Some documents remain ready to retry."))
            } else {
                try await draftStore.setBatchState(.failed, batchID: batchID, errorCategory: "upload_unconfirmed")
                activity = .failed(result.message ?? String(localized: "The upload could not be confirmed. The draft remains safe."))
                historyResult = .unconfirmed
                notificationService.notify(title: String(localized: "Upload not confirmed"), body: String(localized: "The local draft is safe and ready to retry."))
            }
            historyStore.record(.init(
                timestamp: Date(),
                destinationName: profile.displayName,
                destinationHost: profile.host ?? "unknown",
                documentCount: batch.documents.count,
                pageCount: batch.pageCount,
                result: historyResult,
                remoteIDs: result.documentResults.compactMap(\.remoteID),
                batchID: assignedBatch.logicalBatchID,
                documentIDs: assignedBatch.documents.map(\.id),
                requestIDs: result.documentResults.compactMap(\.requestID),
                errorCategory: historyResult == .sent
                    ? nil
                    : UploadFailureClassifier.category(for: result.documentResults),
                openURL: result.documentResults.compactMap(\.openURL).first
            ))
            if profile.openBrowserAfterSend,
               let url = result.documentResults.compactMap(\.openURL).first {
                if OpenURLApprovalStore.isApproved(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    pendingOpenURL = url
                }
            }
        } catch is CancellationError {
            if cancellationIsForTermination {
                try? await draftStore.setBatchState(
                    .failed,
                    batchID: batchID,
                    errorCategory: "operation_interrupted"
                )
            } else {
                let latestBatch = draftStore.batches.first(where: { $0.id == batchID })
                if let latestBatch, latestBatch.documents.contains(where: \.transfer.confirmed) {
                    try? await draftStore.setBatchState(
                        .partiallySent,
                        batchID: batchID,
                        errorCategory: "cancelled_after_partial_success"
                    )
                    if let profile = historyProfile {
                        historyStore.record(.init(
                            timestamp: Date(),
                            destinationName: profile.displayName,
                            destinationHost: profile.host ?? "unknown",
                            documentCount: historyBatch?.documents.count ?? latestBatch.documents.count,
                            pageCount: historyBatch?.pageCount ?? latestBatch.pageCount,
                            result: .partiallySent,
                            remoteIDs: latestBatch.documents.compactMap(\.transfer.remoteID),
                            batchID: latestBatch.logicalBatchID,
                            documentIDs: latestBatch.documents.map(\.id),
                            requestIDs: Array(Set(latestBatch.documents.flatMap { $0.transfer.attempts.map(\.requestID) })),
                            errorCategory: "cancelled_after_partial_success",
                            openURL: latestBatch.documents.compactMap(\.transfer.openURL).first
                        ))
                    }
                } else {
                    try? await draftStore.setBatchState(.ready, batchID: batchID)
                }
            }
            activity = .cancelled
        } catch {
            let errorCategory = UploadFailureClassifier.category(for: error)
            try? await draftStore.setBatchState(.failed, batchID: batchID, errorCategory: errorCategory)
            let activities = documentActivities
            for (documentID, documentActivity) in activities {
                switch documentActivity {
                case .confirmed, .unconfirmed, .failed: break
                default: documentActivities[documentID] = .failed(error.localizedDescription)
                }
            }
            activity = .failed("\(error.localizedDescription) The draft remains safe on this Mac.")
            notificationService.notify(title: String(localized: "Upload failed"), body: String(localized: "The local draft is safe and can be retried."))
            if let profile = historyProfile, let originalBatch = historyBatch {
                let latestBatch = draftStore.batches.first(where: { $0.id == batchID }) ?? originalBatch
                let requestIDs = Array(Set(latestBatch.documents.flatMap { document in
                    document.transfer.attempts.map(\.requestID)
                }))
                historyStore.record(.init(
                    timestamp: Date(),
                    destinationName: profile.displayName,
                    destinationHost: profile.host ?? "unknown",
                    documentCount: originalBatch.documents.count,
                    pageCount: originalBatch.pageCount,
                    result: .failed,
                    remoteIDs: latestBatch.documents.compactMap(\.transfer.remoteID),
                    batchID: latestBatch.logicalBatchID,
                    documentIDs: latestBatch.documents.map(\.id),
                    requestIDs: requestIDs,
                    errorCategory: errorCategory,
                    openURL: latestBatch.documents.compactMap(\.transfer.openURL).first
                ))
            }
        }
        await draftStore.cleanupPreparedOutputs(outputs)
    }

    func approvePendingOpenURL() {
        guard let url = pendingOpenURL else { return }
        OpenURLApprovalStore.approve(url)
        pendingOpenURL = nil
        NSWorkspace.shared.open(url)
    }

    func dismissPendingOpenURL() {
        pendingOpenURL = nil
    }

    func approvePendingRetry() {
        resolveActiveRetryDecision(approved: true)
    }

    func declinePendingRetry() {
        resolveActiveRetryDecision(approved: false)
    }

    private func requestLongRetryConfirmation(seconds: Int) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueueRetryDecision(.init(
                    prompt: .init(id: id, seconds: seconds),
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveRetryDecision(id: id, approved: false)
            }
        }
    }

    private func enqueueRetryDecision(_ decision: PendingRetryDecision) {
        if activeRetryDecision == nil {
            activeRetryDecision = decision
            pendingRetryConfirmation = decision.prompt
        } else {
            queuedRetryDecisions.append(decision)
        }
    }

    private func resolveActiveRetryDecision(approved: Bool) {
        guard let activeRetryDecision else { return }
        resolveRetryDecision(id: activeRetryDecision.prompt.id, approved: approved)
    }

    private func resolveRetryDecision(id: UUID, approved: Bool) {
        if activeRetryDecision?.prompt.id == id {
            let decision = activeRetryDecision
            activeRetryDecision = nil
            pendingRetryConfirmation = nil
            decision?.continuation.resume(returning: approved)
            promoteNextRetryDecision()
            return
        }
        guard let index = queuedRetryDecisions.firstIndex(where: { $0.prompt.id == id }) else { return }
        let decision = queuedRetryDecisions.remove(at: index)
        decision.continuation.resume(returning: approved)
    }

    private func promoteNextRetryDecision() {
        guard activeRetryDecision == nil, !queuedRetryDecisions.isEmpty else { return }
        activeRetryDecision = queuedRetryDecisions.removeFirst()
        pendingRetryConfirmation = activeRetryDecision?.prompt
    }

    private func resolveAllRetryDecisions(approved: Bool) {
        let decisions = [activeRetryDecision].compactMap { $0 } + queuedRetryDecisions
        activeRetryDecision = nil
        queuedRetryDecisions = []
        pendingRetryConfirmation = nil
        decisions.forEach { $0.continuation.resume(returning: approved) }
    }

    private func waitForNetworkIfNeeded(batchID: UUID) async -> Bool {
        guard !networkMonitor.isOnline else { return false }
        try? await draftStore.setBatchState(.waitingForNetwork, batchID: batchID)
        activity = .waitingForNetwork
        await networkMonitor.waitUntilOnline()
        guard !Task.isCancelled else { return true }
        try? await draftStore.setBatchState(.uploading, batchID: batchID)
        activity = .uploading(progress: 0)
        return true
    }

    private func validate(batch: DraftBatch, profile: DestinationProfile) throws {
        if profile.batchPolicy == .oneDocument, batch.actionableDocumentCount > 1 {
            throw UploadEngineError.destinationConstraint(String(localized: "This destination accepts one document per send."))
        }
        if batch.actionableDocumentCount > profile.maximumDocumentsPerBatch {
            throw UploadEngineError.destinationConstraint(String(localized: "The batch exceeds this destination’s document limit."))
        }
        for document in batch.documents where !document.transfer.confirmed {
            if profile.pagePolicy == .singlePage, document.pages.count > 1 {
                throw UploadEngineError.destinationConstraint(String(localized: "This destination accepts one page per document."))
            }
            if let maximum = profile.maximumPagesPerDocument, document.pages.count > maximum {
                throw UploadEngineError.destinationConstraint(String(localized: "A document exceeds this destination’s page limit."))
            }
            if !profile.acceptedOutputFormats.contains(document.outputFormat) {
                throw UploadEngineError.destinationConstraint(String(localized: "This destination does not accept \(document.outputFormat.title)."))
            }
        }
    }

    private func scheduleSentPayloadCleanup() {
        let retentionHours = UserDefaults.standard.object(forKey: "privacy.retentionHours") as? Int ?? 24
        Task { @MainActor [weak draftStore] in
            try? await Task.sleep(for: .seconds(5 * 60))
            guard !Task.isCancelled else { return }
            await draftStore?.cleanupExpired(retentionHours: retentionHours, sentGraceMinutes: 5)
        }
    }

    private func validate(outputs: [PreparedDocument], profile: DestinationProfile) throws {
        if let maximum = profile.maximumFileBytes, outputs.contains(where: { $0.byteCount > maximum }) {
            throw UploadEngineError.outputSizeExceeded(String(localized: "A generated document exceeds the destination’s file-size limit."))
        }
        let total = outputs.reduce(Int64(0)) { $0 + $1.byteCount }
        if let maximum = profile.maximumBatchBytes, total > maximum {
            throw UploadEngineError.outputSizeExceeded(String(localized: "The generated batch exceeds the destination’s total-size limit."))
        }
    }

    private func validateParameters(
        batch: DraftBatch,
        profile: DestinationProfile,
        values: [ParameterValueKey: String]
    ) throws {
        for parameter in profile.parameters where parameter.enabled {
            let documents: [DraftDocument?] = parameter.scope == .document
                ? batch.documents.filter { !$0.transfer.confirmed }.map(Optional.some)
                : [nil]
            for document in documents {
                let value = resolvedValue(
                    parameter,
                    batch: batch,
                    document: document,
                    values: values
                )
                if let issue = DestinationParameterValidator.validate(value: value, for: parameter) {
                    throw UploadEngineError.destinationConstraint(issue)
                }
            }
        }
    }

    private func resolvedValue(
        _ parameter: DestinationParameter,
        batch: DraftBatch,
        document: DraftDocument?,
        values: [ParameterValueKey: String]
    ) -> String? {
        let key = ParameterValueKey(
            parameterID: parameter.id,
            documentID: parameter.scope == .document ? document?.id : nil
        )
        if let value = values[key] ?? values[ParameterValueKey(parameterID: parameter.id, documentID: nil)] {
            return value
        }
        switch parameter.valueSource {
        case .fixed:
            return parameter.value ?? parameter.defaultValue
        case .userEntered:
            return parameter.scope == .document
                ? document?.metadata[parameter.name] ?? parameter.defaultValue
                : batch.metadata[parameter.name] ?? parameter.defaultValue
        case .generated:
            return UUID().uuidString
        case .builtIn:
            switch parameter.builtInValue {
            case .documentID: return document?.id.uuidString
            case .batchID: return batch.logicalBatchID.uuidString
            case .filename: return document?.name
            case .pageCount: return document.map { String($0.pages.count) }
            case .documentCount: return String(batch.actionableDocumentCount)
            case .scannedAt: return ISO8601DateFormatter().string(from: document?.createdAt ?? batch.createdAt)
            case .scannerName: return document?.scanSettings.scannerName ?? batch.documents.first?.scanSettings.scannerName
            case .contentType: return document?.outputFormat.contentType
            case .requestID: return UUID().uuidString
            case .none: return nil
            }
        }
    }
}

enum OpenURLApprovalStore {
    private static let key = "security.approvedAutomaticOpenHosts"

    static func isApproved(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        return Set(defaults.stringArray(forKey: key) ?? []).contains(host)
    }

    static func approve(_ url: URL, defaults: UserDefaults = .standard) {
        guard let host = normalizedHost(url) else { return }
        var hosts = Set(defaults.stringArray(forKey: key) ?? [])
        hosts.insert(host)
        defaults.set(hosts.sorted(), forKey: key)
    }

    private static func normalizedHost(_ url: URL) -> String? {
        guard DestinationValidator.isAllowedTransportURL(url), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        return host
    }
}

enum UploadFailureClassifier {
    static func category(for results: [UploadDocumentResult]) -> String {
        let statuses = results.compactMap(\.statusCode)
        if statuses.contains(where: { $0 == 401 || $0 == 403 }) { return "authentication_failure" }
        if statuses.contains(429) { return "rate_limited" }
        if statuses.contains(408) { return "timeout" }
        if statuses.contains(where: { (500...599).contains($0) }) { return "server_failure" }
        if statuses.contains(where: { (400...499).contains($0) }) { return "receiver_rejected" }
        return statuses.isEmpty ? "network_or_response_unconfirmed" : "response_unconfirmed"
    }

    static func category(for error: Error) -> String {
        if let uploadError = error as? UploadEngineError {
            switch uploadError {
            case .invalidURL, .destinationConstraint:
                return "configuration_failure"
            case .outputSizeExceeded:
                return "output_size_exceeded"
            case .nonHTTPResponse:
                return "invalid_response"
            case .responseTooLarge:
                return "response_too_large"
            case .longRetryDeclined:
                return "retry_declined"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired,
                 .secureConnectionFailed:
                return "tls_failure"
            case .userAuthenticationRequired:
                return "authentication_failure"
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .networkConnectionLost:
                return "network_failure"
            default:
                return "transport_failure"
            }
        }
        return "upload_failed"
    }
}
