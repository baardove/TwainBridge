import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingService
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var destinationStore: DestinationStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var launchAtLoginService: LaunchAtLoginService
    @Environment(\.openSettings) private var openSettings
    @State private var showingTestScan = false
    @State private var testScanExistingIDs: Set<UUID> = []
    @State private var testScanBatchID: UUID?
    @State private var showingTestScanComplete = false
    @State private var isAwaitingTestScan = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Set Up TwainBridge", systemImage: "scanner")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(onboarding.currentStep + 1) of 4")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            ProgressView(value: Double(onboarding.currentStep + 1), total: 4)
                .padding(.horizontal, 24)
            Divider().padding(.top, 16)

            Group {
                switch onboarding.currentStep {
                case 0: privacyStep
                case 1: scannerStep
                case 2: destinationStep
                default: backgroundStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            Divider()
            HStack {
                Button("Back") { onboarding.currentStep = max(0, onboarding.currentStep - 1) }
                    .disabled(onboarding.currentStep == 0)
                Spacer()
                if onboarding.currentStep < 3 {
                    Button("Continue") { onboarding.currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Finish") { onboarding.complete() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 650, height: 500)
        .sheet(isPresented: $showingTestScan, onDismiss: {
            if testScanBatchID == nil { isAwaitingTestScan = false }
        }) {
            ScanAcquisitionView()
                .environmentObject(scannerService)
                .environmentObject(draftStore)
        }
        .onChange(of: draftStore.batches.map(\.id)) { _, currentIDs in
            guard isAwaitingTestScan,
                  testScanBatchID == nil,
                  let newID = currentIDs.first(where: { !testScanExistingIDs.contains($0) }) else { return }
            isAwaitingTestScan = false
            testScanBatchID = newID
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                showingTestScanComplete = true
            }
        }
        .alert("Test Scan Complete", isPresented: $showingTestScanComplete) {
            Button("Discard Test Scan") {
                guard let id = testScanBatchID else { return }
                Task {
                    try? await draftStore.discardBatch(id)
                    testScanBatchID = nil
                    testScanExistingIDs = Set(draftStore.batches.map(\.id))
                }
            }
        } message: {
            Text("The scanner workflow succeeded. The test pages will now be securely removed and will not become a pending draft.")
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor)
            Text("Your scans stay on this Mac")
                .font(.title.weight(.semibold))
            Text("Completed pages are encrypted immediately and remain local until you press Send. TwainBridge never uploads automatically and never modifies watched-folder source files.")
                .font(.body)
            Label("Encrypted drafts recover after a restart", systemImage: "checkmark.circle")
            Label("Destination secrets are stored in Keychain", systemImage: "checkmark.circle")
            Label("Notifications omit filenames and metadata", systemImage: "checkmark.circle")
            Spacer()
        }
    }

    private var scannerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scanner and driver")
                .font(.title.weight(.semibold))
            let status = DriverInspector.epsonDS1660WStatus()
            if status.installed {
                Label(
                    status.verified
                        ? "Epson ICA driver \(status.version ?? "installed") is ready"
                        : "Epson ICA driver \(status.version ?? "unknown") is installed but unverified",
                    systemImage: status.verified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(status.verified ? Color.green : .orange)
            } else {
                Label("Epson ICA driver not found", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Button("Open Epson DS-1660W Support") {
                    NSWorkspace.shared.open(DriverInspector.epsonSupportURL)
                }
            }
            Button("Run Optional Test Scan…") {
                testScanExistingIDs = Set(draftStore.batches.map(\.id))
                testScanBatchID = nil
                isAwaitingTestScan = true
                draftStore.nextScanTarget = .newBatch
                showingTestScan = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(scannerService.scanners.isEmpty)
            .accessibilityIdentifier("onboarding.test-scan")
            if case let .failed(failure) = scannerService.activity {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure.headline, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure.recoverySuggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if failure.category == .permissionDenied {
                        Button("Open Privacy & Security") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            if scannerService.scanners.isEmpty {
                ContentUnavailableView {
                    Label("No Scanner Detected", systemImage: "scanner")
                } description: {
                    Text("Connect the scanner by USB or ensure it is reachable on the network. You may continue and configure it later.")
                } actions: {
                    Button("Search Again") { scannerService.refreshDiscovery() }
                }
            } else {
                ForEach(scannerService.scanners) { scanner in
                    HStack {
                        Image(systemName: "scanner")
                        VStack(alignment: .leading) {
                            Text(scanner.name)
                            Text("\(scanner.connection.rawValue) · \(scanner.location)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Upload destination")
                .font(.title.weight(.semibold))
            Text("Create a destination and enter any required Keychain credential. Test Connection is an optional diagnostic and never sends a real scan.")
            if !networkMonitor.isOnline {
                Label("Offline — destination testing will be available when the network returns", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }
            if let destination = destinationStore.defaultDestination {
                Label(
                    destination.lastConnectionTestSucceeded
                        ? "\(destination.displayName) is tested and ready"
                        : "\(destination.displayName) is ready; connection test optional",
                    systemImage: destination.lastConnectionTestSucceeded ? "checkmark.circle.fill" : "minus.circle"
                )
                .foregroundStyle(destination.lastConnectionTestSucceeded ? Color.green : .secondary)
            } else {
                Label("No destination configured", systemImage: "paperplane")
                    .foregroundStyle(.orange)
            }
            Button("Open Destination Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Text("You may continue without a destination; Send remains disabled until an enabled, valid destination is configured.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backgroundStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Background behavior")
                .font(.title.weight(.semibold))
            Toggle("Launch TwainBridge at login", isOn: Binding(
                get: { launchAtLoginService.isEnabled },
                set: { launchAtLoginService.setEnabled($0) }
            ))
            Toggle("Privacy-preserving notifications", isOn: $notificationService.isEnabled)
            if notificationService.isEnabled && !notificationService.authorizationGranted {
                Button("Allow Notifications") {
                    Task { await notificationService.requestAuthorization() }
                }
            }
            if let error = launchAtLoginService.lastError {
                Text(error).foregroundStyle(.red)
            }
            Text("TwainBridge has no persistent Dock window. Close the workspace whenever you like; drafts remain encrypted and available from the menu bar.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
