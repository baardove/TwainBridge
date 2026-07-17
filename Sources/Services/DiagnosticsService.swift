import Foundation

enum DiagnosticsService {
    static func makeSupportBundle(
        scanners: [ScannerSnapshot],
        scannerActivity: ScannerActivity,
        drafts: [DraftBatch],
        history: [TransferHistoryEntry],
        networkOnline: Bool,
        watchedFolderEnabled: Bool,
        watchedFolderStatus: WatchedFolderService.Status
    ) -> String {
        let driver = DriverInspector.epsonDS1660WStatus()
        let root: [String: Any] = [
            "schema_version": 1,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "application": applicationInfo(),
            "system": [
                "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architecture,
                "network_online": networkOnline
            ],
            "providers": [
                "image_capture_core": frameworkVersion(bundleIdentifier: "com.apple.ImageCaptureCore"),
                "epson_ds_1660w_driver": [
                    "installed": driver.installed,
                    "version": json(driver.version),
                    "meets_pilot_baseline": driver.verified,
                    "required_baseline": DriverInspector.requiredEpsonVersion
                ]
            ],
            "runtime": [
                "scanner_activity": scannerActivitySummary(scannerActivity),
                "watched_folder_enabled": watchedFolderEnabled,
                "watched_folder_state": watchedFolderState(watchedFolderStatus),
                "active_draft_count": drafts.filter { $0.state != .sent }.count
            ],
            "reported_scanners": scanners.map(scannerSummary),
            "active_draft_diagnostics": drafts.filter { $0.state != .sent }.map(draftSummary),
            "recent_transfer_diagnostics": history.prefix(50).map(historySummary)
        ]

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"support_bundle_generation_failed\"}"
        }
        return text
    }

    private static func applicationInfo() -> [String: Any] {
        [
            "name": "TwainBridge",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        ]
    }

    private static func frameworkVersion(bundleIdentifier: String) -> Any {
        guard let bundle = Bundle(identifier: bundleIdentifier) else { return NSNull() }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return json(version)
    }

    private static func scannerSummary(_ scanner: ScannerSnapshot) -> [String: Any] {
        [
            // Persistent ICA IDs and location strings are intentionally excluded;
            // they may contain serial numbers, IP addresses, or user labels.
            "display_name": sanitize(scanner.name, maximum: 120),
            "connection": scanner.connection.rawValue,
            "sources": scanner.capabilities.availableSources.map(\.rawValue).sorted(),
            "resolutions_dpi": scanner.capabilities.resolutions.sorted(),
            "page_sizes": scanner.capabilities.pageSizes.map(\.rawValue),
            "duplex": scanner.capabilities.supportsDuplex,
            "feeder_document_loaded": json(scanner.capabilities.feederDocumentLoaded)
        ]
    }

    private static func draftSummary(_ draft: DraftBatch) -> [String: Any] {
        [
            "batch_id": draft.logicalBatchID.uuidString,
            "state": draft.state.rawValue,
            "document_count": draft.documents.count,
            "page_count": draft.pageCount,
            "error_category": json(draft.lastErrorCategory),
            "documents": draft.documents.map { document in
                [
                    "document_id": document.id.uuidString,
                    "confirmed": document.transfer.confirmed,
                    "attempt_count": document.transfer.attemptCount,
                    "attempts": document.transfer.attempts.map { attempt in
                        [
                            "request_id": attempt.requestID.uuidString,
                            "timestamp": ISO8601DateFormatter().string(from: attempt.attemptedAt),
                            "status_code": json(attempt.statusCode),
                            "outcome": sanitize(attempt.outcome, maximum: 80)
                        ]
                    }
                ] as [String: Any]
            }
        ]
    }

    private static func historySummary(_ entry: TransferHistoryEntry) -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
            "result": entry.result.rawValue,
            "document_count": entry.documentCount,
            "page_count": entry.pageCount,
            "batch_id": entry.batchID.uuidString,
            "document_ids": entry.documentIDs.map(\.uuidString),
            "request_ids": entry.requestIDs.map(\.uuidString),
            "error_category": json(entry.errorCategory)
        ]
    }

    private static func scannerActivitySummary(_ activity: ScannerActivity) -> [String: Any] {
        switch activity {
        case let .failed(failure):
            return [
                "state": "failed",
                "category": failure.category.rawValue,
                "technical_code": json(failure.technicalCode)
            ]
        case .discovering: return ["state": "discovering"]
        case .ready: return ["state": "ready"]
        case .openingSession: return ["state": "opening_session"]
        case .selectingSource: return ["state": "selecting_source"]
        case .scanning: return ["state": "scanning"]
        case .completed: return ["state": "completed"]
        case .unavailable: return ["state": "unavailable"]
        }
    }

    private static func watchedFolderState(_ status: WatchedFolderService.Status) -> String {
        switch status {
        case .disabled: "disabled"
        case .watching: "watching"
        case .importing: "importing"
        case .paused: "paused"
        }
    }

    private static func sanitize(_ value: String, maximum: Int) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(scalars)).prefixString(maximum)
    }

    private static func json<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private extension String {
    func prefixString(_ maximum: Int) -> String { String(prefix(maximum)) }
}
