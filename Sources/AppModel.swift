import Combine
import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppModel: ObservableObject {
    let scannerService: ScannerService
    let draftStore: DraftStore
    let destinationStore: DestinationStore
    let uploadCoordinator: UploadCoordinator
    let workspaceRouter: WorkspaceRouter
    let watchedFolderService: WatchedFolderService
    let historyStore: TransferHistoryStore
    let networkMonitor: NetworkMonitor
    let notificationService: NotificationService
    let launchAtLoginService: LaunchAtLoginService
    let onboardingService: OnboardingService
    let scanDefaultsStore: ScanDefaultsStore
    let hotKeyService: ScanHotKeyService
    let webcamService: WebcamCaptureService
    let updateService: UpdateService

    private var cancellables: Set<AnyCancellable> = []
    private var importingResultIDs: Set<UUID> = []

    init(
        scannerService: ScannerService = ScannerService(),
        draftStore: DraftStore = DraftStore(),
        destinationStore: DestinationStore = DestinationStore()
    ) {
        self.scannerService = scannerService
        self.draftStore = draftStore
        self.destinationStore = destinationStore
        historyStore = TransferHistoryStore()
        networkMonitor = NetworkMonitor()
        notificationService = NotificationService()
        launchAtLoginService = LaunchAtLoginService()
        onboardingService = OnboardingService()
        scanDefaultsStore = ScanDefaultsStore()
        hotKeyService = ScanHotKeyService()
        webcamService = WebcamCaptureService()
        updateService = UpdateService()
        uploadCoordinator = UploadCoordinator(
            draftStore: draftStore,
            destinationStore: destinationStore,
            historyStore: historyStore,
            networkMonitor: networkMonitor,
            notificationService: notificationService
        )
        workspaceRouter = WorkspaceRouter()
        watchedFolderService = WatchedFolderService(draftStore: draftStore)
        draftStore.preferredDestinationID = destinationStore.selectedDestinationID
            ?? destinationStore.defaultDestinationID
        hotKeyService.onScanTrigger = { [weak self] in self?.handleScanHotKey() }
        hotKeyService.onWebcamTrigger = { [weak self] in self?.handleWebcamHotKey() }

        destinationStore.$selectedDestinationID
            .sink { [weak draftStore, weak destinationStore] selectedID in
                draftStore?.preferredDestinationID = selectedID ?? destinationStore?.defaultDestinationID
            }
            .store(in: &cancellables)

        scannerService.$completedScanResult
            .compactMap { $0 }
            .sink { [weak self] result in
                self?.secureCompletedScan(result)
            }
            .store(in: &cancellables)

        webcamService.$completedCaptureResult
            .compactMap { $0 }
            .sink { [weak self] result in
                self?.secureCompletedWebcamCapture(result)
            }
            .store(in: &cancellables)

        scannerService.$hardwareButtonRequestScannerID
            .compactMap { $0 }
            .sink { [weak self] scannerID in self?.handleHardwareButton(scannerID: scannerID) }
            .store(in: &cancellables)

        Task {
            await draftStore.reload()
            let retention = UserDefaults.standard.object(forKey: "privacy.retentionHours") as? Int ?? 24
            await draftStore.cleanupExpired(retentionHours: retention)
            notifyAboutExpiringDrafts(retentionHours: retention)
            await recoverInterruptedUploads()
            if updateService.automaticChecksEnabled,
               !scannerService.activity.isBusy,
               !uploadCoordinator.activity.isBusy {
                await updateService.checkForUpdates()
            }
        }

        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, let self else { return }
                let retention = UserDefaults.standard.object(forKey: "privacy.retentionHours") as? Int ?? 24
                await self.draftStore.cleanupExpired(retentionHours: retention)
            }
        }
    }

    private func notifyAboutExpiringDrafts(retentionHours: Int) {
        let total = Double(max(retentionHours, 1)) * 3600
        let warningWindow = min(6 * 3600, max(3600, total * 0.25))
        let count = draftStore.batches.filter { batch in
            guard batch.state != .sent else { return false }
            let remaining = total - Date().timeIntervalSince(batch.updatedAt)
            return remaining > 0 && remaining <= warningWindow
        }.count
        guard count > 0 else { return }
        notificationService.notify(
            title: String(localized: "Draft retention warning"),
            body: count == 1
                ? String(localized: "1 local draft is nearing expiration. Open TwainBridge to retry, save, or discard.")
                : String(localized: "\(count) local drafts are nearing expiration. Open TwainBridge to retry, save, or discard.")
        )
    }

    private func secureCompletedScan(_ result: CompletedScanResult) {
        guard importingResultIDs.insert(result.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { importingResultIDs.remove(result.id) }
            do {
                _ = try await draftStore.importCompletedScan(result)
                scanDefaultsStore.save(result.request)
                scannerService.acknowledgeCompletedScan()
                workspaceRouter.requestOpenWorkspace()
                notificationService.notify(
                    title: String(localized: "Document ready"),
                    body: String(localized: "A scanned document is ready to review.")
                )
            } catch {
                scannerService.reportDraftImportFailure(error)
            }
        }
    }

    private func handleHardwareButton(scannerID: String) {
        defer { scannerService.acknowledgeHardwareButtonRequest() }
        guard draftStore.actionableCount < 20 else {
            notificationService.notify(
                title: String(localized: "Draft limit reached"),
                body: String(localized: "Send, save, or discard a local draft before using the scanner button again.")
            )
            return
        }
        guard !scannerService.activity.isBusy else {
            notificationService.notify(
                title: String(localized: "Scanner is busy"),
                body: String(localized: "Use Scan New Document again after the active acquisition finishes.")
            )
            return
        }
        guard !webcamService.isSessionRunning, !webcamService.activity.isBusy else {
            notificationService.notify(
                title: String(localized: "Webcam capture is active"),
                body: String(localized: "Finish or close webcam capture before using the scanner button.")
            )
            return
        }
        draftStore.nextScanTarget = .newBatch
        scannerService.selectedScannerID = scannerID
        scannerService.startScan(scanDefaultsStore.request(for: scannerID))
        #if canImport(AppKit)
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first(where: { $0.title == "TwainBridge" })?.makeKeyAndOrderFront(nil)
        #endif
    }

    private func handleScanHotKey() {
        workspaceRouter.requestOpenWorkspace()
        #if canImport(AppKit)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        guard let scannerID = scannerService.selectedScanner?.id else {
            notificationService.notify(
                title: String(localized: "Scan shortcut needs a scanner"),
                body: String(localized: "Connect or select a scanner, then use the shortcut again.")
            )
            return
        }
        guard draftStore.actionableCount < 20 else {
            notificationService.notify(
                title: String(localized: "Draft limit reached"),
                body: String(localized: "Send, save, or discard a local draft before using the scan shortcut again.")
            )
            return
        }
        guard !scannerService.activity.isBusy else {
            notificationService.notify(
                title: String(localized: "Scanner is busy"),
                body: String(localized: "Use the scan shortcut again after the active acquisition finishes.")
            )
            return
        }
        guard !webcamService.isSessionRunning, !webcamService.activity.isBusy else {
            notificationService.notify(
                title: String(localized: "Webcam capture is active"),
                body: String(localized: "Finish or close webcam capture before starting a scanner acquisition.")
            )
            return
        }
        guard !scannerService.hasUnsecuredCapturedPages else {
            notificationService.notify(
                title: String(localized: "Secure the completed pages first"),
                body: String(localized: "Keep, continue, or discard the interrupted scan before starting another one.")
            )
            return
        }

        draftStore.nextScanTarget = .newBatch
        scannerService.selectedScannerID = scannerID
        scannerService.startScan(scanDefaultsStore.request(for: scannerID))
    }

    private func handleWebcamHotKey() {
        #if canImport(AppKit)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        guard draftStore.actionableCount < 20 else {
            notificationService.notify(
                title: String(localized: "Draft limit reached"),
                body: String(localized: "Send, save, or discard a local draft before using webcam capture.")
            )
            return
        }
        guard !scannerService.activity.isBusy else {
            notificationService.notify(
                title: String(localized: "Scanner is busy"),
                body: String(localized: "Finish the active scan before using webcam capture.")
            )
            return
        }
        guard !webcamService.hasUnsecuredCapturedPhoto else {
            notificationService.notify(
                title: String(localized: "Secure the captured photo first"),
                body: String(localized: "Retry or discard the pending webcam photo before taking another one.")
            )
            return
        }
        draftStore.nextScanTarget = .newBatch
        workspaceRouter.requestOpenWebcam()
    }

    private func secureCompletedWebcamCapture(_ result: CompletedScanResult) {
        guard importingResultIDs.insert(result.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { importingResultIDs.remove(result.id) }
            do {
                _ = try await draftStore.importCompletedScan(result)
                webcamService.acknowledgeCompletedCapture()
                workspaceRouter.requestOpenWorkspace()
                notificationService.notify(
                    title: String(localized: "Webcam document ready"),
                    body: String(localized: "A webcam photo is ready to review.")
                )
            } catch {
                webcamService.reportDraftImportFailure(error)
            }
        }
    }

    /// Cancels active work and gives completed scanner pages time to enter the
    /// encrypted draft store before AppKit allows the process to exit.
    func prepareForTermination() async -> Bool {
        scannerService.prepareForTermination()
        webcamService.prepareForTermination()
        uploadCoordinator.cancelForTermination()

        for _ in 0..<100 {
            if !scannerService.activity.isBusy,
               !scannerService.hasUnsecuredCapturedPages,
               !webcamService.hasUnsecuredCapturedPhoto,
               !uploadCoordinator.activity.isBusy {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Upload state is already persisted before transmission. Scanner pages
        // are the only data that must block termination if local import stalled.
        return !scannerService.hasUnsecuredCapturedPages && !webcamService.hasUnsecuredCapturedPhoto
    }

    private func recoverInterruptedUploads() async {
        let interrupted = draftStore.batches.filter { $0.lastErrorCategory == "operation_interrupted" }
        for batch in interrupted {
            guard let destinationID = batch.destinationID,
                  let profile = destinationStore.profile(id: destinationID),
                  profile.enabled else {
                try? await draftStore.setBatchState(
                    .failed,
                    batchID: batch.id,
                    errorCategory: "destination_unavailable_after_restart"
                )
                continue
            }

            guard profile.receiverSupportsIdempotency else {
                try? await draftStore.setBatchState(
                    .failed,
                    batchID: batch.id,
                    errorCategory: "ambiguous_transmission"
                )
                notificationService.notify(
                    title: String(localized: "Upload needs confirmation"),
                    body: String(localized: "An interrupted transfer is preserved and requires a manual retry decision.")
                )
                continue
            }

            uploadCoordinator.startSend(batchID: batch.id, destinationID: destinationID)
            while uploadCoordinator.activeBatchID != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
