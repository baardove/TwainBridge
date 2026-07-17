import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var destinationStore: DestinationStore
    @EnvironmentObject private var watchedFolderService: WatchedFolderService
    @EnvironmentObject private var historyStore: TransferHistoryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var launchAtLoginService: LaunchAtLoginService
    @EnvironmentObject private var onboardingService: OnboardingService
    @EnvironmentObject private var uploadCoordinator: UploadCoordinator
    @EnvironmentObject private var updateService: UpdateService
    @EnvironmentObject private var scanDefaultsStore: ScanDefaultsStore
    @EnvironmentObject private var hotKeyService: ScanHotKeyService
    @EnvironmentObject private var webcamService: WebcamCaptureService

    var body: some View {
        TabView {
            DestinationSettingsView()
                .tabItem { Label("Destinations", systemImage: "paperplane") }

            ScannerSettingsView()
                .environmentObject(scannerService)
                .environmentObject(draftStore)
                .environmentObject(watchedFolderService)
                .environmentObject(scanDefaultsStore)
                .environmentObject(hotKeyService)
                .environmentObject(webcamService)
                .tabItem { Label("Scanning", systemImage: "scanner") }

            GeneralSettingsView()
                .environmentObject(scannerService)
                .environmentObject(draftStore)
                .environmentObject(watchedFolderService)
                .environmentObject(historyStore)
                .environmentObject(networkMonitor)
                .environmentObject(notificationService)
                .environmentObject(launchAtLoginService)
                .environmentObject(onboardingService)
                .environmentObject(uploadCoordinator)
                .environmentObject(updateService)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 900, height: 650)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var watchedFolderService: WatchedFolderService
    @EnvironmentObject private var historyStore: TransferHistoryStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var launchAtLoginService: LaunchAtLoginService
    @EnvironmentObject private var onboardingService: OnboardingService
    @EnvironmentObject private var uploadCoordinator: UploadCoordinator
    @EnvironmentObject private var updateService: UpdateService
    @AppStorage("privacy.retentionHours") private var retentionHours = 24
    @AppStorage("document.defaultOutputFormat") private var defaultOutputFormat = DocumentOutputFormat.pdf.rawValue
    @AppStorage("document.defaultCompressionPreset") private var defaultCompressionPreset = ""
    @AppStorage("document.defaultFilenamePattern") private var defaultFilenamePattern = "document-{document_id}"
    @State private var confirmClearDrafts = false
    @State private var diagnosticPreview: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginService.isEnabled },
                    set: { launchAtLoginService.setEnabled($0) }
                ))
                Toggle("Privacy-preserving notifications", isOn: $notificationService.isEnabled)
                if notificationService.isEnabled && !notificationService.authorizationGranted {
                    Button("Request Notification Permission") {
                        Task { await notificationService.requestAuthorization() }
                    }
                }
                LabeledContent("Network", value: networkMonitor.isOnline ? "Online" : "Offline")
                LabeledContent("Version", value: appVersion)
                Button("Run Setup Assistant Again") { onboardingService.restart() }
            }

            Section("Updates") {
                Toggle("Check automatically", isOn: $updateService.automaticChecksEnabled)
                LabeledContent("Status", value: updateService.status.label)
                HStack {
                    Button("Check Now") {
                        Task { await updateService.checkForUpdates() }
                    }
                    .disabled(updateService.status.isBusy || activeDeviceOrNetworkWork)
                    if updateService.availableManifest != nil,
                       updateService.verifiedPackageURL == nil {
                        Button("Download & Verify") {
                            Task { await updateService.downloadAndVerifyAvailableUpdate() }
                        }
                        .disabled(updateService.status.isBusy || activeDeviceOrNetworkWork)
                    }
                    if updateService.verifiedPackageURL != nil {
                        Button("Open Verified Update") { updateService.openVerifiedUpdate() }
                            .disabled(activeDeviceOrNetworkWork)
                    }
                }
                Text("The HTTPS manifest is Ed25519-signed and the package hash is verified before it can be opened. Installation never starts while scanning or uploading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Document defaults") {
                Picker("Output format", selection: $defaultOutputFormat) {
                    ForEach(DocumentOutputFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("PDF and image quality", selection: $defaultCompressionPreset) {
                    Text("Original Quality").tag("")
                    ForEach(OutputCompressionPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                TextField("New destination filename pattern", text: $defaultFilenamePattern)
                Text("Available placeholders: {document_id}, {batch_id}, {index}, {name}, and {date}. Oversized output always asks before compression or lower-resolution rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Keep new captures in the encrypted Document Library", isOn: Binding(
                    get: { draftStore.keepNewCapturesInLibrary },
                    set: { draftStore.setKeepNewCapturesInLibrary($0) }
                ))
                LabeledContent("Library storage") {
                    Text("\(draftStore.libraryBatches.count) items · \(ByteCountFormatter.string(fromByteCount: draftStore.libraryByteCount, countStyle: .file))")
                }
                Text("The library keeps encrypted scanner documents, webcam photos, and watched-folder imports after upload. Turn this off for future captures that should follow temporary-draft retention instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("Retain actionable drafts for \(retentionHours) hours", value: $retentionHours, in: 1...720)
                Button("Run Retention Cleanup Now") {
                    Task { await draftStore.cleanupExpired(retentionHours: retentionHours) }
                }
                Button("Clear Temporary Documents…", role: .destructive) { confirmClearDrafts = true }
            }

            Section("Recent transfers") {
                Toggle("Keep metadata-only transfer history", isOn: $historyStore.isEnabled)
                if historyStore.entries.isEmpty {
                    Text("No recent transfers").foregroundStyle(.secondary)
                } else {
                    ForEach(historyStore.entries.prefix(10)) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.destinationName)
                                Text("\(entry.documentCount) document(s), \(entry.pageCount) page(s)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.result.rawValue).font(.caption)
                            Text(entry.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if let openURL = entry.openURL {
                                Button("Open in Browser") { NSWorkspace.shared.open(openURL) }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                    Button("Clear History", role: .destructive) { historyStore.clear() }
                }
                Text("History contains no scan payloads, thumbnails, filenames, credentials, metadata values, query strings, or response bodies.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Copy Sanitized Diagnostic Summary") {
                    copyDiagnostics()
                }
                Button("Review & Export Support Bundle…") {
                    diagnosticPreview = makeDiagnostics()
                }
                Text("The support bundle excludes scan content, thumbnails, filenames, folder paths, destination URLs, credentials, metadata values, query strings, and response bodies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove all local drafts?",
            isPresented: $confirmClearDrafts,
            titleVisibility: .visible
        ) {
            Button("Remove Drafts", role: .destructive) {
                Task { await draftStore.clearTemporaryDocuments() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Temporary encrypted drafts will be removed. Document Library items and active uploads are not deleted.")
        }
        .sheet(isPresented: Binding(
            get: { diagnosticPreview != nil },
            set: { if !$0 { diagnosticPreview = nil } }
        )) {
            supportBundleReview
        }
    }

    private var supportBundleReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Support Bundle").font(.title2.weight(.semibold))
            Text("Only the JSON shown below will be exported.")
                .foregroundStyle(.secondary)
            TextEditor(text: .constant(diagnosticPreview ?? ""))
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 700, minHeight: 420)
                .border(.quaternary)
                .accessibilityLabel("Sanitized support bundle preview")
            HStack {
                Button("Copy") { copyDiagnostics() }
                Spacer()
                Button("Cancel", role: .cancel) { diagnosticPreview = nil }
                Button("Export JSON…") { exportDiagnostics() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func makeDiagnostics() -> String {
        DiagnosticsService.makeSupportBundle(
            scanners: scannerService.scanners,
            scannerActivity: scannerService.activity,
            drafts: draftStore.batches,
            history: historyStore.entries,
            networkOnline: networkMonitor.isOnline,
            watchedFolderEnabled: watchedFolderService.isEnabled,
            watchedFolderStatus: watchedFolderService.status
        )
    }

    private var activeDeviceOrNetworkWork: Bool {
        scannerService.activity.isBusy || uploadCoordinator.activity.isBusy
    }

    private func copyDiagnostics() {
        let text = diagnosticPreview ?? makeDiagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "twainbridge-support-bundle.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data((diagnosticPreview ?? makeDiagnostics()).utf8).write(to: url, options: .atomic)
            diagnosticPreview = nil
        } catch {
            NSSound.beep()
        }
    }
}

private struct DestinationSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @State private var editor: DestinationProfile?
    @State private var credential = ""
    @State private var parameterSecrets: [UUID: String] = [:]
    @State private var connectionResult: ConnectionTestResult?
    @State private var isTesting = false
    @State private var saveMessage: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            Group {
                if let editorBinding = Binding($editor) {
                    DestinationEditorView(
                        profile: editorBinding,
                        credential: $credential,
                        parameterSecrets: $parameterSecrets,
                        issues: store.validationIssues(for: editorBinding.wrappedValue),
                        connectionResult: connectionResult,
                        isTesting: isTesting,
                        onSave: save,
                        onTest: testConnection
                    )
                } else {
                    ContentUnavailableView {
                        Label("No Destination", systemImage: "paperplane")
                    } description: {
                        Text("Create an HTTPS destination to enable Send.")
                    } actions: {
                        Button("New Destination", action: addDestination)
                    }
                }
            }
            .frame(minWidth: 640)
        }
        .onAppear {
            if store.selectedDestinationID == nil { store.selectedDestinationID = store.profiles.first?.id }
            loadSelection()
        }
        .onChange(of: store.selectedDestinationID) { _, _ in loadSelection() }
        .alert("Destination", isPresented: Binding(
            get: { saveMessage != nil },
            set: { if !$0 { saveMessage = nil } }
        )) {
            Button("OK") { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedDestinationID) {
                ForEach(store.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            Text(profile.host ?? "Not configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: destinationConnectionStatusSymbol(profile))
                            .foregroundStyle(destinationConnectionStatusColor(profile))
                            .help(destinationConnectionStatusLabel(profile))
                            .accessibilityLabel(destinationConnectionStatusLabel(profile))
                        if store.defaultDestinationID == profile.id {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color.accentColor)
                                .help("Default destination")
                                .accessibilityLabel("Default destination")
                        }
                    }
                    .tag(Optional(profile.id))
                }
            }

            Divider()
            HStack {
                Button(action: addDestination) { Image(systemName: "plus") }
                    .help("Add destination")
                    .accessibilityLabel("Add destination")
                Button(action: deleteDestination) { Image(systemName: "minus") }
                    .help("Delete destination")
                    .accessibilityLabel("Delete destination")
                    .disabled(editor == nil)
                Spacer()
                Menu {
                    Button("Set as Default") {
                        if let id = editor?.id { store.setDefault(id) }
                    }
                    Button("Export Profile…", action: exportProfile)
                        .disabled(editor == nil)
                    Button("Import Profile…", action: importProfile)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Destination actions")
            }
            .padding(8)
        }
    }

    private func loadSelection() {
        guard let profile = store.profile(id: store.selectedDestinationID) else {
            editor = nil
            credential = ""
            parameterSecrets = [:]
            return
        }
        editor = profile
        credential = store.credential(for: profile.id) ?? ""
        parameterSecrets = Dictionary(uniqueKeysWithValues: profile.parameters.filter(\.sensitive).map {
            ($0.id, store.parameterSecret(profileID: profile.id, parameterID: $0.id) ?? "")
        })
        connectionResult = nil
    }

    private func addDestination() {
        let profile = store.createDestination()
        store.selectedDestinationID = profile.id
        loadSelection()
    }

    private func deleteDestination() {
        guard let id = editor?.id else { return }
        do { try store.delete(id); loadSelection() } catch { saveMessage = error.localizedDescription }
    }

    private func save() {
        guard var editor else { return }
        editor.lastConnectionTestSucceeded = false
        do {
            try store.save(editor, credential: credential)
            for (parameterID, value) in parameterSecrets {
                try store.setParameterSecret(value, profileID: editor.id, parameterID: parameterID)
            }
            self.editor = store.profile(id: editor.id)
            saveMessage = String(localized: "Destination saved. Test Connection is available as an optional diagnostic.")
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func testConnection() {
        guard let editor else { return }
        do {
            try store.save(editor, credential: credential)
            for (parameterID, value) in parameterSecrets {
                try store.setParameterSecret(value, profileID: editor.id, parameterID: parameterID)
            }
        } catch {
            connectionResult = .init(outcome: .invalidResponse, summary: error.localizedDescription)
            return
        }

        isTesting = true
        connectionResult = nil
        Task {
            let result = await DestinationConnectionTester().test(
                profile: editor,
                credential: credential,
                parameterSecrets: parameterSecrets
            )
            connectionResult = result
            isTesting = false
            do {
                try store.recordConnectionTest(profileID: editor.id, result: result)
                self.editor = store.profile(id: editor.id)
            } catch {
                saveMessage = error.localizedDescription
            }
        }
    }

    private func exportProfile() {
        guard let id = editor?.id else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "twainbridge-destination.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportProfile(id).write(to: url, options: .atomic) } catch { saveMessage = error.localizedDescription }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.importProfile(Data(contentsOf: url))
            store.selectedDestinationID = imported.id
            loadSelection()
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}

private struct DestinationEditorView: View {
    @Binding var profile: DestinationProfile
    @Binding var credential: String
    @Binding var parameterSecrets: [UUID: String]
    let issues: [DestinationValidationIssue]
    let connectionResult: ConnectionTestResult?
    let isTesting: Bool
    let onSave: () -> Void
    let onTest: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Destination") {
                    TextField("Display name", text: $profile.displayName)
                    TextField("Destination URL", text: $profile.endpointURL, prompt: Text("https://example.com/api/scans or http://localhost:9080/upload"))
                    Picker("HTTP method", selection: $profile.method) {
                        ForEach(HTTPMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Body encoding", value: "multipart/form-data")
                    TextField("File field", text: $profile.fileFieldName)
                    TextField("Filename pattern", text: $profile.filenamePattern)
                    Stepper("Timeout: \(Int(profile.requestTimeout)) seconds", value: $profile.requestTimeout, in: 1...600)
                }

                Section("Authentication") {
                    Picker("Type", selection: $profile.authentication.kind) {
                        ForEach(AuthenticationKind.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.authentication.kind == .customHeader {
                        TextField("Header name", text: $profile.authentication.headerName)
                    }
                    if profile.authentication.kind != .none {
                        SecureField("Credential", text: $credential)
                        Text("Stored in macOS Keychain; never included in profile exports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Documents & pages") {
                    Picker("Pages per document", selection: $profile.pagePolicy) {
                        Text("Single page").tag(PagePolicy.singlePage)
                        Text("Multiple pages").tag(PagePolicy.multiplePages)
                    }
                    if profile.pagePolicy == .singlePage {
                        Picker("Extra scanned pages", selection: $profile.singlePageOverflow) {
                            Text("Start a new document").tag(SinglePageOverflowBehavior.startNewDocument)
                            Text("Ask").tag(SinglePageOverflowBehavior.ask)
                            Text("Reject").tag(SinglePageOverflowBehavior.reject)
                        }
                    }
                    OptionalLimitField(title: "Maximum pages", value: $profile.maximumPagesPerDocument)
                    Picker("Documents per send", selection: $profile.batchPolicy) {
                        Text("One document").tag(BatchPolicy.oneDocument)
                        Text("Multiple documents").tag(BatchPolicy.multipleDocuments)
                    }
                    if profile.batchPolicy == .multipleDocuments {
                        Stepper(
                            "Maximum documents: \(profile.maximumDocumentsPerBatch)",
                            value: $profile.maximumDocumentsPerBatch,
                            in: 1...20
                        )
                        Picker("Request mode", selection: $profile.batchRequestMode) {
                            Text("One multipart request").tag(BatchRequestMode.oneMultipartRequest)
                            Text("One request per document").tag(BatchRequestMode.oneRequestPerDocument)
                        }
                        Picker("Partial success", selection: $profile.partialSuccessBehavior) {
                            Text("Keep only failed documents").tag(PartialSuccessBehavior.keepFailedOnly)
                            Text("Keep the complete batch").tag(PartialSuccessBehavior.keepCompleteBatch)
                        }
                    }
                    Toggle("Document order is significant", isOn: $profile.documentOrderSignificant)
                    Toggle("Accept PDF", isOn: outputFormatBinding(.pdf))
                    Toggle("Accept JPEG", isOn: outputFormatBinding(.jpeg))
                    OptionalByteLimitField(title: "Maximum file size", value: $profile.maximumFileBytes)
                    OptionalByteLimitField(title: "Maximum batch size", value: $profile.maximumBatchBytes)
                    if profile.batchRequestMode == .oneMultipartRequest {
                        Picker("File fields", selection: $profile.fileFieldConvention) {
                            Text("Repeat field name").tag(FileFieldConvention.repeated)
                            Text("Indexed field names").tag(FileFieldConvention.indexed)
                            Text("Custom field per document").tag(FileFieldConvention.customPerDocument)
                        }
                        if profile.fileFieldConvention == .customPerDocument {
                            TextField(
                                "File field pattern",
                                text: bindingWithDefault($profile.customFileFieldPattern, "file-{index}")
                            )
                            Text("Use {index}, {document_id}, or {file_field}.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Include JSON manifest", isOn: $profile.includeBatchManifest)
                        if profile.includeBatchManifest {
                            TextField("Manifest field", text: $profile.manifestFieldName)
                        }
                    } else {
                        Picker("Request concurrency", selection: $profile.requestConcurrency) {
                            Text("Sequential").tag(RequestConcurrency.sequential)
                            Text("Two at a time").tag(RequestConcurrency.twoAtATime)
                        }
                    }
                }

                Section("Posting parameters") {
                    ForEach($profile.parameters) { $parameter in
                        ParameterEditorRow(
                            parameter: $parameter,
                            secret: secretBinding(for: parameter.id),
                            canMoveUp: parameterPosition(parameter.id).map { $0 > 0 } ?? false,
                            canMoveDown: parameterPosition(parameter.id).map { $0 < profile.parameters.count - 1 } ?? false,
                            onMoveUp: { moveParameter(parameter.id, offset: -1) },
                            onMoveDown: { moveParameter(parameter.id, offset: 1) },
                            onDelete: { deleteParameter(parameter.id) }
                        )
                    }
                    .onDelete { profile.parameters.remove(atOffsets: $0) }

                    Button("Add Parameter") {
                        profile.parameters.append(DestinationParameter())
                    }
                }

                Section("Response") {
                    Picker("Mode", selection: $profile.response.mode) {
                        Text("Standard TwainBridge JSON").tag(ResponseMode.standardJSON)
                        Text("Status only").tag(ResponseMode.statusOnly)
                        Text("Custom JSON").tag(ResponseMode.customJSON)
                    }
                    HStack {
                        Text("Success status")
                        TextField("From", value: $profile.response.successStatuses.lowerBound, format: .number)
                            .frame(width: 60)
                        Text("through")
                        TextField("To", value: $profile.response.successStatuses.upperBound, format: .number)
                            .frame(width: 60)
                    }
                    Toggle("Permit empty response", isOn: $profile.response.permitsEmptyBody)
                    TextField("Expected Content-Type", text: $profile.response.expectedContentType)
                    Stepper(
                        "Maximum response: \(ByteCountFormatter.string(fromByteCount: Int64(profile.response.maximumBodyBytes), countStyle: .file))",
                        value: $profile.response.maximumBodyBytes,
                        in: 0...10_485_760,
                        step: 65_536
                    )
                    Toggle("Allow missing optional response fields", isOn: $profile.response.missingOptionalFieldsAllowed)
                    if profile.response.mode == .customJSON {
                        TextField("Success JSON path", text: $profile.response.custom.successPath)
                        TextField("Message JSON path", text: $profile.response.custom.messagePath)
                        TextField("Remote ID JSON path", text: $profile.response.custom.remoteIDPath)
                        TextField("Open URL JSON path", text: $profile.response.custom.openURLPath)
                        if profile.batchPolicy == .multipleDocuments && profile.batchRequestMode == .oneMultipartRequest {
                            TextField("Documents array JSON path", text: $profile.response.custom.documentsPath)
                            TextField("Document identifier JSON path", text: $profile.response.custom.documentIdentifierPath)
                        }
                    }
                    Toggle("Receiver supports idempotency", isOn: $profile.receiverSupportsIdempotency)
                    TextField("Idempotency header", text: $profile.idempotencyHeaderName)
                    Toggle("Open verified result in browser after send", isOn: $profile.openBrowserAfterSend)
                    TextField("Allowed redirect hosts", text: Binding(
                        get: { profile.allowedRedirectHosts.joined(separator: ", ") },
                        set: { profile.allowedRedirectHosts = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } }
                    ))
                    Text("Redirects and open URLs are restricted to the destination host and this comma-separated allowlist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !issues.isEmpty {
                    Section("Validation") {
                        ForEach(issues) { issue in
                            Label(
                                issue.message,
                                systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(issue.severity == .error ? Color.red : .orange)
                        }
                    }
                }

                Section("Sanitized request preview") {
                    LabeledContent("URL", value: sanitizedURL)
                    LabeledContent("Headers", value: headerNames)
                    LabeledContent("Form fields", value: formNames)
                    Text("Values marked sensitive are omitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let connectionResult {
                    Label(
                        connectionResultText(connectionResult),
                        systemImage: connectionResult.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(connectionResult.succeeded ? Color.green : .red)
                    .lineLimit(2)
                } else {
                    Label(
                        destinationConnectionStatusLabel(profile),
                        systemImage: destinationConnectionStatusSymbol(profile)
                    )
                    .foregroundStyle(destinationConnectionStatusColor(profile))
                }
                Spacer()
                Button("Save", action: onSave)
                Button(action: onTest) {
                    if isTesting { ProgressView().controlSize(.small) } else { Text("Test Connection") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)
                .accessibilityLabel(
                    isTesting ? String(localized: "Testing connection") : String(localized: "Test connection")
                )
                .help("Sends a generated one-page twainbridge-test.pdf; no scanned document is used.")
                .accessibilityIdentifier("destination.test")
            }
            .padding(12)
        }
    }

    private func secretBinding(for id: UUID) -> Binding<String> {
        Binding(get: { parameterSecrets[id, default: ""] }, set: { parameterSecrets[id] = $0 })
    }

    private func outputFormatBinding(_ format: DocumentOutputFormat) -> Binding<Bool> {
        Binding(
            get: { profile.acceptedOutputFormats.contains(format) },
            set: { enabled in
                if enabled { profile.acceptedOutputFormats.insert(format) }
                else { profile.acceptedOutputFormats.remove(format) }
            }
        )
    }

    private func parameterPosition(_ id: UUID) -> Int? {
        profile.parameters.firstIndex { $0.id == id }
    }

    private func moveParameter(_ id: UUID, offset: Int) {
        guard let source = parameterPosition(id) else { return }
        let destination = source + offset
        guard profile.parameters.indices.contains(destination) else { return }
        profile.parameters.swapAt(source, destination)
    }

    private func deleteParameter(_ id: UUID) {
        profile.parameters.removeAll { $0.id == id }
        parameterSecrets[id] = nil
    }

    private var sanitizedURL: String {
        guard var components = URLComponents(string: profile.endpointURL) else {
            return String(localized: "Invalid URL")
        }
        components.queryItems = profile.parameters.filter { $0.enabled && $0.location == .query }.map {
            URLQueryItem(name: $0.name, value: $0.sensitive ? "••••" : previewValue(for: $0))
        }
        return (components.string ?? String(localized: "Invalid URL"))
            .replacingOccurrences(of: "{", with: "‹")
            .replacingOccurrences(of: "}", with: "›")
    }

    private var headerNames: String {
        var fields = profile.parameters.filter { $0.enabled && $0.location == .header }.map {
            "\($0.name): \($0.sensitive ? "‹secret›" : previewValue(for: $0))"
        }
        if profile.authentication.kind != .none {
            fields.append("\(profile.authentication.headerName): ‹Keychain secret›")
        }
        fields.append("\(profile.idempotencyHeaderName): ‹logical ID›")
        return fields.joined(separator: ", ")
    }

    private var formNames: String {
        var fields = ["\(profile.fileFieldName): ‹document file›"]
        fields.append(contentsOf: profile.parameters.filter { $0.enabled && $0.location == .form }.map {
            "\($0.name): \($0.sensitive ? "‹secret›" : previewValue(for: $0))"
        })
        if profile.includeBatchManifest && profile.batchRequestMode == .oneMultipartRequest {
            fields.append("\(profile.manifestFieldName): ‹JSON manifest›")
        }
        return fields.joined(separator: ", ")
    }

    private func previewValue(for parameter: DestinationParameter) -> String {
        switch parameter.valueSource {
        case .fixed:
            return parameter.value ?? parameter.defaultValue ?? "‹value›"
        case .userEntered:
            return parameter.defaultValue ?? "‹user value›"
        case .generated:
            return "‹generated value›"
        case .builtIn:
            return parameter.builtInValue.map { "‹\($0.rawValue)›" } ?? "‹built-in value›"
        }
    }

    private func connectionResultText(_ result: ConnectionTestResult) -> String {
        guard let statusCode = result.statusCode else { return result.summary }
        return String(localized: "HTTP \(statusCode) · \(result.summary)")
    }
}

private struct ParameterEditorRow: View {
    @Binding var parameter: DestinationParameter
    @Binding var secret: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            Picker("Location", selection: $parameter.location) {
                ForEach(ParameterLocation.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Value source", selection: $parameter.valueSource) {
                ForEach(ParameterValueSource.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Scope", selection: $parameter.scope) {
                ForEach(ParameterScope.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Data type", selection: $parameter.dataType) {
                ForEach(ParameterDataType.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            if parameter.valueSource == .builtIn {
                Picker("Built-in value", selection: $parameter.builtInValue) {
                    Text("Choose…").tag(Optional<BuiltInParameterValue>.none)
                    ForEach(BuiltInParameterValue.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
            } else if parameter.valueSource == .fixed {
                if parameter.sensitive {
                    SecureField("Keychain value", text: $secret)
                } else {
                    TextField("Value", text: bindingWithDefault($parameter.value, ""))
                }
            }
            if parameter.valueSource == .userEntered {
                TextField("User label", text: bindingWithDefault($parameter.label, ""))
                TextField("Help text", text: bindingWithDefault($parameter.helpText, ""))
                if !parameter.sensitive {
                    TextField("Default value", text: bindingWithDefault($parameter.defaultValue, ""))
                }
                Toggle("Reuse last value for this destination", isOn: $parameter.rememberValue)
            }
            if parameter.dataType == .choice {
                TextField("Allowed values, comma separated", text: Binding(
                    get: { parameter.allowedValues.joined(separator: ", ") },
                    set: { parameter.allowedValues = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
                ))
            }
            if parameter.dataType == .integer || parameter.dataType == .decimal {
                HStack {
                    TextField("Minimum", value: $parameter.minimum, format: .number)
                    TextField("Maximum", value: $parameter.maximum, format: .number)
                }
            }
            TextField("Maximum length", value: $parameter.maximumLength, format: .number)
            TextField("Validation expression", text: bindingWithDefault($parameter.validationExpression, ""))
            Toggle("Required", isOn: $parameter.required)
            Toggle("Sensitive", isOn: $parameter.sensitive)
                .disabled(parameter.location == .query)
        } label: {
            HStack {
                Toggle(isOn: $parameter.enabled) { EmptyView() }
                    .labelsHidden()
                    .accessibilityLabel(
                        parameter.name.isEmpty
                            ? String(localized: "Enable parameter")
                            : String(localized: "Enable \(parameter.name)")
                    )
                TextField("Parameter name", text: $parameter.name)
                Text(parameter.location.rawValue.capitalized)
                    .foregroundStyle(.secondary)
                Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveUp)
                    .help("Move parameter up")
                Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                    .labelStyle(.iconOnly)
                    .disabled(!canMoveDown)
                    .help("Move parameter down")
                Button("Delete Parameter", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .help("Delete parameter")
            }
        }
    }
}

private struct OptionalLimitField: View {
    let title: String
    @Binding var value: Int?

    var body: some View {
        Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? 100) : nil })) {
            HStack {
                Text(title)
                Spacer()
                if value != nil {
                    TextField("Limit", value: bindingWithDefault($value, 100), format: .number)
                        .frame(width: 80)
                }
            }
        }
    }
}

private struct OptionalByteLimitField: View {
    let title: String
    @Binding var value: Int64?

    var body: some View {
        Toggle(isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? 10_000_000) : nil })) {
            HStack {
                Text(title)
                Spacer()
                if value != nil {
                    TextField("Bytes", value: bindingWithDefault($value, 10_000_000), format: .number)
                        .frame(width: 110)
                    Text(ByteCountFormatter.string(fromByteCount: value ?? 0, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

private struct ScannerSettingsView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var watchedFolderService: WatchedFolderService
    @EnvironmentObject private var scanDefaultsStore: ScanDefaultsStore
    @EnvironmentObject private var hotKeyService: ScanHotKeyService
    @EnvironmentObject private var webcamService: WebcamCaptureService
    @State private var folderError: String?
    @State private var defaultsRequest: ScanRequest?
    @State private var scanProfileMessage: String?

    var body: some View {
        Form {
            Section("Default scanner and scan settings") {
                if scannerService.scanners.isEmpty {
                    Text("Connect a scanner to configure its defaults.").foregroundStyle(.secondary)
                } else {
                    Picker("Default scanner", selection: $scannerService.selectedScannerID) {
                        ForEach(scannerService.scanners) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Source", selection: requestBinding(\.source, fallback: .automatic)) {
                        ForEach(sourceChoices, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    Picker("Sides", selection: requestBinding(\.duplex, fallback: false)) {
                        Text("Single-sided").tag(false)
                        Text("Duplex").tag(true)
                    }
                    .disabled(requestBinding(\.source, fallback: .automatic).wrappedValue == .flatbed || !selectedCapabilities.supportsDuplex)
                    Picker("Color", selection: requestBinding(\.colorMode, fallback: .color)) {
                        ForEach(ScanColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Resolution", selection: requestBinding(\.resolution, fallback: 300)) {
                        ForEach(selectedCapabilities.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                    }
                    Picker("Page size", selection: requestBinding(\.pageSize, fallback: .automatic)) {
                        ForEach(selectedCapabilities.pageSizes) { Text($0.title).tag($0) }
                    }
                    Picker("Orientation", selection: requestBinding(\.orientation, fallback: .automatic)) {
                        ForEach(ScanOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button("Save Scanner Defaults") {
                            if let defaultsRequest { scanDefaultsStore.save(defaultsRequest) }
                        }
                        Button("Export Scan Profile…", action: exportScanProfile)
                        Button("Import Scan Profile…", action: importScanProfile)
                    }
                    .disabled(defaultsRequest == nil)
                }
            }
            Section("Global scan shortcut") {
                Toggle("Enable global scan shortcut", isOn: $hotKeyService.scanConfiguration.enabled)
                HStack {
                    Picker("Key", selection: $hotKeyService.scanConfiguration.keyCode) {
                        ForEach(ScanHotKeyKey.options) { key in
                            Text(key.label).tag(key.keyCode)
                        }
                    }
                    .frame(width: 150)
                    Toggle("Command", isOn: $hotKeyService.scanConfiguration.command)
                    Toggle("Option", isOn: $hotKeyService.scanConfiguration.option)
                    Toggle("Control", isOn: $hotKeyService.scanConfiguration.control)
                    Toggle("Shift", isOn: $hotKeyService.scanConfiguration.shift)
                }
                .disabled(!hotKeyService.scanConfiguration.enabled)
                LabeledContent("Current shortcut", value: hotKeyService.scanConfiguration.displayName)
                if let error = hotKeyService.scanRegistrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if hotKeyService.scanConfiguration.enabled && hotKeyService.isScanRegistered {
                    Label("The shortcut is active system-wide.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack {
                    Button("Reset to ⌥⌘S") { hotKeyService.resetScan() }
                    Text("The shortcut starts a new scan immediately with the selected scanner and its saved defaults. It does not require Accessibility permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Webcam capture") {
                if webcamService.cameras.isEmpty {
                    Text("No webcam currently detected. Built-in, USB, and Continuity cameras are supported.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default webcam", selection: $webcamService.selectedCameraID) {
                        ForEach(webcamService.cameras) { camera in
                            Text(camera.name).tag(Optional(camera.id))
                        }
                    }
                }
                Toggle("Enable global webcam shortcut", isOn: $hotKeyService.webcamConfiguration.enabled)
                HStack {
                    Picker("Key", selection: $hotKeyService.webcamConfiguration.keyCode) {
                        ForEach(ScanHotKeyKey.options) { key in
                            Text(key.label).tag(key.keyCode)
                        }
                    }
                    .frame(width: 150)
                    Toggle("Command", isOn: $hotKeyService.webcamConfiguration.command)
                    Toggle("Option", isOn: $hotKeyService.webcamConfiguration.option)
                    Toggle("Control", isOn: $hotKeyService.webcamConfiguration.control)
                    Toggle("Shift", isOn: $hotKeyService.webcamConfiguration.shift)
                }
                .disabled(!hotKeyService.webcamConfiguration.enabled)
                LabeledContent("Current shortcut", value: hotKeyService.webcamConfiguration.displayName)
                if let error = hotKeyService.webcamRegistrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if hotKeyService.webcamConfiguration.enabled && hotKeyService.isWebcamRegistered {
                    Label("The webcam shortcut is active system-wide.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack {
                    Button("Reset to ⌥⌘C") { hotKeyService.resetWebcam() }
                    Text("The shortcut opens a live camera preview. Captured photos enter the same encrypted draft and upload workflow as scanner pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Detected scanners") {
                if scannerService.scanners.isEmpty {
                    Text("No scanners detected").foregroundStyle(.secondary)
                } else {
                    ForEach(scannerService.scanners) { scanner in
                        LabeledContent(scanner.name, value: scanner.connection.rawValue)
                    }
                }
            }
            Section("Local drafts") {
                LabeledContent("Actionable drafts", value: "\(draftStore.actionableCount)")
                if let error = draftStore.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("Watched folder") {
                Toggle("Import stable scanner files automatically", isOn: $watchedFolderService.isEnabled)
                LabeledContent(
                    "Folder",
                    value: watchedFolderService.folderURL?.path(percentEncoded: false) ?? "Not selected"
                )
                LabeledContent("Status", value: watchedFolderService.status.label)
                if let error = watchedFolderService.lastImportError {
                    Text(error).foregroundStyle(.red)
                }
                HStack {
                    Button("Choose Folder…", action: chooseFolder)
                    Button("Check Now") { watchedFolderService.checkNow() }
                        .disabled(watchedFolderService.folderURL == nil || !watchedFolderService.isEnabled)
                    Button("Import File Again…", action: importAgain)
                        .disabled(watchedFolderService.folderURL == nil)
                    Button("Remove", role: .destructive) { watchedFolderService.clearFolder() }
                        .disabled(watchedFolderService.folderURL == nil)
                }
                Text("PDF, JPEG, PNG, and TIFF files are copied into encrypted drafts only after remaining unchanged across two checks. Source files are never modified or deleted. Use Import File Again for an intentional duplicate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadDefaults)
        .onChange(of: scannerService.selectedScannerID) { _, _ in loadDefaults() }
        .onChange(of: defaultsRequest?.source) { _, source in
            if let source { scannerService.prepareCapabilities(for: source) }
        }
        .onChange(of: scannerService.selectedScanner?.capabilities) { _, _ in loadDefaults() }
        .alert("Watched Folder", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )) {
            Button("OK") { folderError = nil }
        } message: {
            Text(folderError ?? "")
        }
        .alert("Scan Profile", isPresented: Binding(
            get: { scanProfileMessage != nil },
            set: { if !$0 { scanProfileMessage = nil } }
        )) {
            Button("OK") { scanProfileMessage = nil }
        } message: {
            Text(scanProfileMessage ?? "")
        }
    }

    private var selectedCapabilities: ScannerCapabilities {
        scannerService.selectedScanner?.capabilities ?? .unavailable
    }

    private var sourceChoices: [ScanSource] {
        let choices = selectedCapabilities.sourceChoices
        return choices.isEmpty ? [.automatic] : choices
    }

    private func requestBinding<T>(
        _ keyPath: WritableKeyPath<ScanRequest, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { defaultsRequest?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var request = defaultsRequest else { return }
                request[keyPath: keyPath] = value
                defaultsRequest = request
            }
        )
    }

    private func loadDefaults() {
        guard let scanner = scannerService.selectedScanner else {
            defaultsRequest = nil
            return
        }
        var request = scanDefaultsStore.request(for: scanner.id)
        request.scannerID = scanner.id
        if !scanner.capabilities.sourceChoices.contains(request.source) { request.source = .automatic }
        if !scanner.capabilities.resolutions.contains(request.resolution) {
            request.resolution = scanner.capabilities.resolutions.min(by: { abs($0 - 300) < abs($1 - 300) }) ?? 300
        }
        if !scanner.capabilities.pageSizes.contains(request.pageSize) { request.pageSize = .automatic }
        if request.source == .flatbed || !scanner.capabilities.supportsDuplex { request.duplex = false }
        defaultsRequest = request
    }

    private func exportScanProfile() {
        guard let defaultsRequest else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "twainbridge-scan-profile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try scanDefaultsStore.exportProfile(defaultsRequest).write(to: url, options: .atomic)
        } catch { scanProfileMessage = error.localizedDescription }
    }

    private func importScanProfile() {
        guard let scannerID = scannerService.selectedScannerID else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            defaultsRequest = try scanDefaultsStore.importProfile(Data(contentsOf: url), scannerID: scannerID)
            loadDefaults()
            scanProfileMessage = String(localized: "Scan profile imported for the selected scanner.")
        } catch { scanProfileMessage = error.localizedDescription }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Watch Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try watchedFolderService.chooseFolder(url) }
        catch { folderError = error.localizedDescription }
    }

    private func importAgain() {
        guard let folderURL = watchedFolderService.folderURL else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = folderURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Again"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { _ = try await watchedFolderService.importAgain(url) }
            catch { folderError = error.localizedDescription }
        }
    }
}

private func destinationConnectionStatusLabel(_ profile: DestinationProfile) -> String {
    if profile.lastConnectionTestSucceeded { return String(localized: "Connection tested") }
    if profile.lastConnectionTestAt != nil { return String(localized: "Last connection test failed") }
    return String(localized: "Connection not tested (optional)")
}

private func destinationConnectionStatusSymbol(_ profile: DestinationProfile) -> String {
    if profile.lastConnectionTestSucceeded { return "checkmark.circle.fill" }
    if profile.lastConnectionTestAt != nil { return "xmark.circle.fill" }
    return "minus.circle"
}

private func destinationConnectionStatusColor(_ profile: DestinationProfile) -> Color {
    if profile.lastConnectionTestSucceeded { return .green }
    if profile.lastConnectionTestAt != nil { return .red }
    return .secondary
}

@MainActor
private func bindingWithDefault<T: Sendable>(_ source: Binding<T?>, _ fallback: T) -> Binding<T> {
    Binding(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0 })
}
