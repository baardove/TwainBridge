import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var destinationStore: DestinationStore
    @EnvironmentObject private var uploadCoordinator: UploadCoordinator
    @EnvironmentObject private var onboardingService: OnboardingService
    @EnvironmentObject private var workspaceRouter: WorkspaceRouter
    @EnvironmentObject private var historyStore: TransferHistoryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var watchedFolderService: WatchedFolderService
    @EnvironmentObject private var hotKeyService: ScanHotKeyService
    @EnvironmentObject private var webcamService: WebcamCaptureService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(scannerService.activity.isBusy ? Color.accentColor : .primary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("TwainBridge")
                            .font(.headline)
                        Text(appVersion)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 20)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if scannerService.scanners.isEmpty {
                    HStack {
                        Label("No scanner detected", systemImage: "scanner")
                        Spacer()
                        Button("Search Again") { scannerService.refreshDiscovery() }
                    }
                    Text("Drafts and watched-folder imports remain available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Scanner", selection: selectedScannerBinding) {
                        ForEach(scannerService.scanners) { scanner in
                            Text(scanner.name).tag(Optional(scanner.id))
                        }
                    }
                    if let scanner = scannerService.selectedScanner {
                        Label(
                            "\(scanner.connection.rawValue) · \(scanner.location)",
                            systemImage: scanner.connection == .network ? "network" : "cable.connector"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if destinationStore.profiles.isEmpty {
                    Button("Configure Upload Destination…") {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } else {
                    Picker("Destination", selection: $destinationStore.selectedDestinationID) {
                        ForEach(destinationStore.profiles) { profile in
                            Text(profile.displayName).tag(Optional(profile.id))
                        }
                    }
                }

                Button {
                    workspaceRouter.requestScan()
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Scan New Document", systemImage: "doc.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    scannerService.scanners.isEmpty
                        || scannerService.activity.isBusy
                        || webcamService.isSessionRunning
                        || draftStore.actionableCount >= 20
                )

                Button {
                    draftStore.nextScanTarget = .newBatch
                    workspaceRouter.requestOpenWebcam()
                    openWindow(id: "webcam")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Capture with Webcam", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(
                    scannerService.activity.isBusy
                        || webcamService.hasUnsecuredCapturedPhoto
                        || draftStore.actionableCount >= 20
                )

                Button {
                    openWindow(id: "library")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Label("Document Library", systemImage: "books.vertical")
                        Spacer()
                        Text("\(draftStore.libraryBatches.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                if hotKeyService.scanConfiguration.enabled {
                    Label(
                        hotKeyService.isScanRegistered
                            ? String(localized: "Scan shortcut: \(hotKeyService.scanConfiguration.displayName)")
                            : String(localized: "Scan shortcut unavailable"),
                        systemImage: "keyboard"
                    )
                    .font(.caption)
                    .foregroundStyle(hotKeyService.isScanRegistered ? Color.secondary : Color.orange)
                }
                if hotKeyService.webcamConfiguration.enabled {
                    Label(
                        hotKeyService.isWebcamRegistered
                            ? String(localized: "Webcam shortcut: \(hotKeyService.webcamConfiguration.displayName)")
                            : String(localized: "Webcam shortcut unavailable"),
                        systemImage: "keyboard"
                    )
                    .font(.caption)
                    .foregroundStyle(hotKeyService.isWebcamRegistered ? Color.secondary : Color.orange)
                }

                if draftStore.actionableCount >= 20 {
                    Label("Draft limit reached — send, save, or discard a draft before scanning", systemImage: "tray.full.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if scannerService.hasUnsecuredCapturedPages {
                    Button {
                        scannerService.retrySecuringCapturedPages()
                    } label: {
                        Label("Retry Securing Captured Pages", systemImage: "lock.rotation")
                    }
                    Text("Completed pages are still in private staging and have not been discarded.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if webcamService.hasUnsecuredCapturedPhoto {
                    HStack {
                        Button("Retry Securing Webcam Photo") {
                            webcamService.retrySecuringCapturedPhoto()
                        }
                        Button("Discard Photo", role: .destructive) {
                            webcamService.discardPendingCapture()
                        }
                    }
                    Text("The captured webcam photo remains in private staging until it can be encrypted into a draft.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                let actionable = draftStore.batches.filter { $0.state != .sent }
                if actionable.count == 1, let only = actionable.first {
                    Button("Open Current Document") { openDraft(only) }
                }
                if !actionable.isEmpty {
                    Divider()
                    HStack {
                        Label("Drafts", systemImage: "doc.on.doc")
                        Spacer()
                        Text("\(actionable.count)").foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(.medium))

                    ForEach(actionable.prefix(4)) { batch in
                        Button { openDraft(batch) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(batch.documents.first?.name ?? "Draft").lineLimit(1)
                                    Spacer()
                                    Text(batch.state.title).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text("\(batch.documents.count) doc · \(batch.pageCount) pg")
                                    if let destination = destinationStore.profile(id: batch.destinationID) {
                                        Text("· \(destination.displayName)").lineLimit(1)
                                    }
                                    Spacer()
                                    Text(batch.updatedAt, style: .relative)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let recent = historyStore.entries.first {
                    Divider()
                    HStack {
                        Label("Last transfer", systemImage: recent.result == .sent ? "checkmark.circle" : "exclamationmark.circle")
                        Spacer()
                        Text(recent.result.rawValue).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let setupAction {
                    Button {
                        if setupAction.opensOnboarding {
                            openWindow(id: "workspace")
                        } else {
                            openSettings()
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label(setupAction.label, systemImage: setupAction.systemImage)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if !networkMonitor.isOnline {
                    Label("Offline — drafts remain local", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if watchedFolderService.isEnabled {
                    Label(watchedFolderService.status.label, systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider()

            HStack {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
        .frame(width: 380)
    }

    private var selectedScannerBinding: Binding<String?> {
        Binding(
            get: { scannerService.selectedScannerID },
            set: { scannerService.selectedScannerID = $0 }
        )
    }

    private var statusLabel: String {
        if uploadCoordinator.activity.isBusy { return String(localized: "Uploading documents…") }
        return scannerService.activity.label
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private var statusSymbol: String {
        if uploadCoordinator.activity.isBusy { return "arrow.up.circle.fill" }
        if scannerService.activity.isBusy { return "scanner.fill" }
        if draftStore.batches.contains(where: { [.failed, .interrupted, .partiallySent].contains($0.state) }) {
            return "exclamationmark.triangle.fill"
        }
        if draftStore.actionableCount > 0 { return "doc.badge.ellipsis" }
        if historyStore.entries.first?.result == .sent { return "checkmark.circle.fill" }
        return "scanner"
    }

    private var setupAction: (label: String, systemImage: String, opensOnboarding: Bool)? {
        if !onboardingService.isComplete {
            return (
                String(localized: "Finish first-run setup"),
                "checklist",
                true
            )
        }
        guard let destination = destinationStore.defaultDestination else {
            return (
                String(localized: "Choose an upload destination in Settings"),
                "paperplane",
                false
            )
        }
        if !destination.enabled {
            return (
                String(localized: "Enable \(destination.displayName) in Settings"),
                "exclamationmark.circle",
                false
            )
        }
        return nil
    }

    private func openDraft(_ batch: DraftBatch) {
        draftStore.selectedBatchID = batch.id
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
    }
}
