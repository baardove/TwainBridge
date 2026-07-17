import AppKit
import SwiftUI

@main
struct TwainBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        appDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.scannerService)
                .environmentObject(model.draftStore)
                .environmentObject(model.destinationStore)
                .environmentObject(model.uploadCoordinator)
                .environmentObject(model.workspaceRouter)
                .environmentObject(model.watchedFolderService)
                .environmentObject(model.historyStore)
                .environmentObject(model.networkMonitor)
                .environmentObject(model.notificationService)
                .environmentObject(model.launchAtLoginService)
                .environmentObject(model.onboardingService)
                .environmentObject(model.scanDefaultsStore)
                .environmentObject(model.hotKeyService)
                .environmentObject(model.webcamService)
        } label: {
            MenuBarLabel()
                .environmentObject(model.scannerService)
                .environmentObject(model.draftStore)
                .environmentObject(model.destinationStore)
                .environmentObject(model.uploadCoordinator)
                .environmentObject(model.workspaceRouter)
                .environmentObject(model.watchedFolderService)
                .environmentObject(model.historyStore)
                .environmentObject(model.networkMonitor)
                .environmentObject(model.notificationService)
                .environmentObject(model.launchAtLoginService)
                .environmentObject(model.onboardingService)
                .environmentObject(model.scanDefaultsStore)
                .environmentObject(model.hotKeyService)
                .environmentObject(model.webcamService)
        }
        .menuBarExtraStyle(.window)

        Window("TwainBridge", id: "workspace") {
            WorkspaceView()
                .environmentObject(model.scannerService)
                .environmentObject(model.draftStore)
                .environmentObject(model.destinationStore)
                .environmentObject(model.uploadCoordinator)
                .environmentObject(model.workspaceRouter)
                .environmentObject(model.watchedFolderService)
                .environmentObject(model.historyStore)
                .environmentObject(model.networkMonitor)
                .environmentObject(model.notificationService)
                .environmentObject(model.launchAtLoginService)
                .environmentObject(model.onboardingService)
                .environmentObject(model.scanDefaultsStore)
                .environmentObject(model.hotKeyService)
                .environmentObject(model.webcamService)
        }
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 680)

        Window("Webcam Capture", id: "webcam") {
            WebcamCaptureView()
                .environmentObject(model.webcamService)
                .environmentObject(model.scannerService)
                .environmentObject(model.draftStore)
        }
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 680)

        Window("Document Library", id: "library") {
            DocumentLibraryView()
                .environmentObject(model.draftStore)
                .environmentObject(model.destinationStore)
        }
        .defaultPosition(.center)
        .defaultSize(width: 1050, height: 700)

        Settings {
            SettingsView()
                .environmentObject(model.scannerService)
                .environmentObject(model.draftStore)
                .environmentObject(model.destinationStore)
                .environmentObject(model.watchedFolderService)
                .environmentObject(model.historyStore)
                .environmentObject(model.networkMonitor)
                .environmentObject(model.notificationService)
                .environmentObject(model.launchAtLoginService)
                .environmentObject(model.onboardingService)
                .environmentObject(model.uploadCoordinator)
                .environmentObject(model.updateService)
                .environmentObject(model.scanDefaultsStore)
                .environmentObject(model.hotKeyService)
                .environmentObject(model.webcamService)
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var uploadCoordinator: UploadCoordinator
    @EnvironmentObject private var historyStore: TransferHistoryStore
    @EnvironmentObject private var workspaceRouter: WorkspaceRouter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("TwainBridge", systemImage: symbolName)
            .onChange(of: workspaceRouter.openWorkspaceToken) { _, _ in
                openWindow(id: "workspace")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onChange(of: workspaceRouter.openWebcamToken) { _, _ in
                openWindow(id: "webcam")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }

    private var symbolName: String {
        if uploadCoordinator.activity.isBusy { return "arrow.up.circle.fill" }
        if scannerService.activity.isBusy { return "scanner.fill" }
        if draftStore.batches.contains(where: { [.failed, .interrupted, .partiallySent].contains($0.state) }) {
            return "exclamationmark.triangle.fill"
        }
        if draftStore.actionableCount > 0 { return "doc.badge.ellipsis" }
        if historyStore.entries.first?.result == .sent { return "checkmark.circle.fill" }
        return "scanner"
    }
}
