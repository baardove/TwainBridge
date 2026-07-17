import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var destinationStore: DestinationStore
    @EnvironmentObject private var uploadCoordinator: UploadCoordinator
    @EnvironmentObject private var workspaceRouter: WorkspaceRouter
    @EnvironmentObject private var onboardingService: OnboardingService
    @EnvironmentObject private var notificationService: NotificationService
    @EnvironmentObject private var webcamService: WebcamCaptureService
    @EnvironmentObject private var scanDefaultsStore: ScanDefaultsStore
    @EnvironmentObject private var launchAtLoginService: LaunchAtLoginService
    @Environment(\.openSettings) private var openSettings
    @AppStorage("privacy.retentionHours") private var retentionHours = 24

    @State private var selectedDocumentID: UUID?
    @State private var selectedPageID: UUID?
    @State private var showingScanSetup = false
    @State private var deletion: DeletionRequest?
    @AppStorage("workspace.previewZoom") private var zoom = 1.0
    @AppStorage("workspace.previewFitMode") private var fitMode: PreviewFitMode = .page
    @State private var operationMessage: String?
    @State private var sensitiveMetadata: [ParameterValueKey: String] = [:]
    @State private var ephemeralMetadata: [ParameterValueKey: String] = [:]
    @State private var confirmAmbiguousRetry = false
    @State private var showingSizeOptions = false
    @State private var confirmSinglePageSplit = false
    @State private var confirmAddPagesAsNewDocument = false
    @State private var confirmDestinationHostChange = false
    @State private var showingAdvancedWorkspace = false

    var body: some View {
        transferDialogs
    }

    private var workspaceContent: some View {
        Group {
            if showingAdvancedWorkspace {
                advancedWorkspaceContent
            } else {
                simpleWorkspaceContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            normalizeSelection()
            restoreDestinationForSelectedBatch()
            if draftStore.batches.isEmpty && onboardingService.isComplete { showingScanSetup = true }
            if destinationStore.selectedDestinationID == nil {
                destinationStore.selectedDestinationID = destinationStore.defaultDestinationID
            }
        }
        .onChange(of: draftStore.selectedBatchID) { _, _ in
            normalizeSelection()
            restoreDestinationForSelectedBatch()
            showingAdvancedWorkspace = false
        }
        .onChange(of: draftStore.selectedBatch?.updatedAt) { _, _ in normalizeSelection() }
        .onChange(of: workspaceRouter.scanRequestToken) { _, _ in
            draftStore.nextScanTarget = workspaceRouter.requestedTarget
            showingScanSetup = true
        }
        .sheet(isPresented: $showingScanSetup) {
            ScanAcquisitionView()
                .environmentObject(scannerService)
                .environmentObject(draftStore)
                .environmentObject(scanDefaultsStore)
                .environmentObject(webcamService)
        }
        .sheet(isPresented: Binding(
            get: { !onboardingService.isComplete },
            set: { _ in }
        )) {
            OnboardingView()
                .environmentObject(onboardingService)
                .environmentObject(scannerService)
                .environmentObject(destinationStore)
                .environmentObject(notificationService)
                .environmentObject(launchAtLoginService)
                .interactiveDismissDisabled()
        }
    }

    private var advancedWorkspaceContent: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if let batch = draftStore.selectedBatch, batch.state == .interrupted {
                interruptedScanBanner(batch: batch)
                Divider()
            }
            if let batch = draftStore.selectedBatch, shouldWarnAboutExpiration(batch) {
                expirationBanner(batch: batch)
                Divider()
            }
            if let batch = draftStore.selectedBatch, !batch.documents.isEmpty {
                HSplitView {
                    documentSidebar(batch: batch)
                        .frame(minWidth: 205, idealWidth: 230, maxWidth: 280)
                    pageSidebar(batch: batch)
                        .frame(minWidth: 155, idealWidth: 180, maxWidth: 230)
                    previewWorkspace(batch: batch)
                        .frame(minWidth: 560)
                }
            } else {
                emptyWorkspace
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 980, minHeight: 640)
    }

    private var simpleWorkspaceContent: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if let batch = draftStore.selectedBatch, batch.state == .interrupted {
                interruptedScanBanner(batch: batch)
                Divider()
            }
            if let batch = draftStore.selectedBatch, shouldWarnAboutExpiration(batch) {
                expirationBanner(batch: batch)
                Divider()
            }
            if let batch = draftStore.selectedBatch, !batch.documents.isEmpty {
                simpleDocumentPreview(batch: batch)
            } else {
                emptyWorkspace
            }
            Divider()
            simpleActionBar
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var editingDialogs: some View {
        workspaceContent
        .confirmationDialog(
            deletion?.title ?? "Remove?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(deletion?.buttonTitle ?? "Remove", role: .destructive, action: performDeletion)
            Button("Cancel", role: .cancel) { deletion = nil }
        } message: {
            Text(deletion?.message ?? "")
        }
        .alert("TwainBridge", isPresented: Binding(
            get: { operationMessage != nil },
            set: { if !$0 { operationMessage = nil } }
        )) {
            Button("OK") { operationMessage = nil }
        } message: {
            Text(operationMessage ?? "")
        }
        .confirmationDialog(
            "Retry an unconfirmed transfer?",
            isPresented: $confirmAmbiguousRetry,
            titleVisibility: .visible
        ) {
            Button("Retry Upload") { send() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The previous attempt may have reached the receiver, and this destination does not declare idempotency support. Retrying can create a duplicate remote record.")
        }
        .confirmationDialog(
            "Output exceeds the destination limit",
            isPresented: $showingSizeOptions,
            titleVisibility: .visible
        ) {
            Button("Compress Copy — Balanced") { applyCompressionPreset(.balanced) }
            Button("Compress Copy — Smaller File") { applyCompressionPreset(.smaller) }
            Button("Rescan at Lower Resolution…") { rescanSelectedDocument() }
            Button("Save Copy…") { saveCopy() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(compressionOptionsMessage)
        }
        .confirmationDialog(
            "Split pages into separate documents?",
            isPresented: $confirmSinglePageSplit,
            titleVisibility: .visible
        ) {
            Button("Split and Send") { splitSinglePageDocumentsAndSend() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This destination accepts one page per document. Each additional page will become a new document with its own document ID before sending.")
        }
        .confirmationDialog(
            "Scan into a new document?",
            isPresented: $confirmAddPagesAsNewDocument,
            titleVisibility: .visible
        ) {
            Button("Scan as New Document", action: startNewDocumentScan)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This destination accepts one page per document. The new scan can be added to this batch as a separate document.")
        }
    }

    private var transferDialogs: some View {
        editingDialogs
        .confirmationDialog(
            "Change upload destination host?",
            isPresented: $confirmDestinationHostChange,
            titleVisibility: .visible
        ) {
            Button("Change Host and Send", action: continueSendChecks)
            Button("Cancel", role: .cancel) { }
        } message: {
            if let change = destinationHostChange {
                Text("This draft was assigned to \(change.oldHost). Sending to \(change.newHost) creates a new logical batch ID to prevent cross-system idempotency collisions.")
            }
        }
        .confirmationDialog(
            "The receiver requested a long retry delay",
            isPresented: retryApprovalPresented,
            titleVisibility: .visible
        ) {
            Button("Wait and Retry") { uploadCoordinator.approvePendingRetry() }
            Button("Do Not Retry This Request", role: .cancel) { uploadCoordinator.declinePendingRetry() }
        } message: {
            Text("The receiver asked TwainBridge to retry in \(uploadCoordinator.pendingRetryConfirmation?.seconds ?? 0) seconds. Confirm to keep this draft paused and retry after that delay.")
        }
        .confirmationDialog(
            "Open the receiver page in your browser?",
            isPresented: openURLApprovalPresented,
            titleVisibility: .visible
        ) {
            Button("Open and Remember This Host") { uploadCoordinator.approvePendingOpenURL() }
            Button("Not Now", role: .cancel) { uploadCoordinator.dismissPendingOpenURL() }
        } message: {
            Text("The receiver requested an automatic browser open for \(uploadCoordinator.pendingOpenURL?.host ?? "this host"). TwainBridge asks once before allowing automatic opens for each host.")
        }
    }

    private var retryApprovalPresented: Binding<Bool> {
        Binding(
            get: { uploadCoordinator.pendingRetryConfirmation != nil },
            set: { if !$0 { uploadCoordinator.declinePendingRetry() } }
        )
    }

    private var openURLApprovalPresented: Binding<Bool> {
        Binding(
            get: { uploadCoordinator.pendingOpenURL != nil },
            set: { if !$0 { uploadCoordinator.dismissPendingOpenURL() } }
        )
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(draftStore.selectedBatch?.documents.first?.name ?? "TwainBridge")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showingAdvancedWorkspace {
                Button {
                    showingAdvancedWorkspace = false
                } label: {
                    Label("Simple View", systemImage: "rectangle.compress.vertical")
                }
                .help("Return to the focused send view")
                .accessibilityIdentifier("workspace.simple")
            }
            if let batch = draftStore.selectedBatch {
                Text("\(batch.documents.count) document\(batch.documents.count == 1 ? "" : "s") · \(batch.pageCount) page\(batch.pageCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func simpleDocumentPreview(batch: DraftBatch) -> some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .underPageBackgroundColor)
            if let document = selectedDocument(in: batch), let page = selectedPage(in: document) {
                GeometryReader { proxy in
                    let size = simpleFittedImageSize(page: page, container: proxy.size)
                    DraftPageImage(
                        batchID: batch.id,
                        documentID: document.id,
                        page: page
                    )
                    .rotationEffect(.degrees(Double(page.rotation.rawValue)))
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                }
            } else {
                ContentUnavailableView("No Page Selected", systemImage: "doc")
            }

            let references = simplePageReferences(in: batch)
            if references.count > 1 {
                let index = simplePageIndex(in: references)
                HStack(spacing: 10) {
                    Button {
                        moveSimplePage(by: -1, in: batch)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous page")
                    .accessibilityLabel("Previous page")
                    .disabled(index == 0)

                    Text("\(index + 1) of \(references.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54)

                    Button {
                        moveSimplePage(by: 1, in: batch)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next page")
                    .accessibilityLabel("Next page")
                    .disabled(index >= references.count - 1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 14)
            }
        }
    }

    private var simpleActionBar: some View {
        VStack(spacing: 0) {
            if hasAuthenticationFailure {
                HStack {
                    Label("The destination rejected authentication. Open Advanced to update its credential.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            } else if let conflict = destinationConflicts.first {
                HStack {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            HStack(spacing: 12) {
                Button {
                    showingAdvancedWorkspace = true
                } label: {
                    Label("Advanced…", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("workspace.advanced")

                Spacer()

                if uploadCoordinator.activity.isBusy {
                    ProgressView(value: uploadProgress)
                        .frame(width: 120)
                        .accessibilityLabel(statusText)
                    Button("Cancel", role: .cancel) { uploadCoordinator.cancel() }
                        .accessibilityIdentifier("upload.cancel")
                } else if draftStore.selectedBatch?.state == .sent {
                    Button("Send Again as New Copy", action: duplicateForSendAgain)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("draft.send-again")
                } else {
                    Button(sendButtonTitle, action: requestSend)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .accessibilityIdentifier("draft.send")
                }
            }
            .padding(16)
        }
    }

    private func interruptedScanBanner(batch: DraftBatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The scan stopped before it finished.")
                    .font(.subheadline.weight(.semibold))
                Text("The \(batch.pageCount) captured page\(batch.pageCount == 1 ? " is" : "s are") encrypted and safe on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep Pages") {
                Task {
                    do { try await draftStore.setBatchState(.ready, batchID: batch.id) }
                    catch { operationMessage = error.localizedDescription }
                }
            }
            .help("Keep the captured pages and finish editing")
            Button("Continue Scanning") {
                guard let document = selectedDocument(in: batch) else { return }
                draftStore.nextScanTarget = .appendPages(batchID: batch.id, documentID: document.id)
                showingScanSetup = true
            }
            .buttonStyle(.borderedProminent)
            Button("Discard", role: .destructive) {
                deletion = .batch(batchID: batch.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interrupted scan recovery")
    }

    private func expirationBanner(batch: DraftBatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("This draft is nearing its retention limit.")
                    .font(.subheadline.weight(.semibold))
                Text("It will be removed \(expirationTimeRemaining(batch)) unless you retry, save a copy, or discard it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Retry", action: requestSend).disabled(!canSend)
            Button("Save Copy…") { saveCopy() }
            Button("Discard", role: .destructive) { deletion = .batch(batchID: batch.id) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Draft retention warning")
    }

    private func shouldWarnAboutExpiration(_ batch: DraftBatch) -> Bool {
        guard batch.state != .sent else { return false }
        let total = Double(max(retentionHours, 1)) * 3600
        let remaining = total - Date().timeIntervalSince(batch.updatedAt)
        let warningWindow = min(6 * 3600, max(3600, total * 0.25))
        return remaining > 0 && remaining <= warningWindow
    }

    private func expirationTimeRemaining(_ batch: DraftBatch) -> String {
        let expiry = batch.updatedAt.addingTimeInterval(Double(max(retentionHours, 1)) * 3600)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: expiry, relativeTo: Date())
    }

    private func documentSidebar(batch: DraftBatch) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("DOCUMENTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(draftStore.batches) { draft in
                        Button {
                            draftStore.selectedBatchID = draft.id
                        } label: {
                            Text("\(draft.documents.first?.name ?? "Draft") — \(draft.state.title)")
                        }
                    }
                } label: {
                    Image(systemName: "tray.full")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Open another draft")
                .help("Open another draft")
            }
            .padding(12)

            List(selection: $selectedDocumentID) {
                ForEach(Array(batch.documents.enumerated()), id: \.element.id) { index, document in
                    DocumentRow(
                        index: index,
                        document: document,
                        uploadActivity: uploadCoordinator.activeBatchID == batch.id
                            ? uploadCoordinator.documentActivities[document.id]
                            : nil
                    )
                        .tag(Optional(document.id))
                }
                .onMove { offsets, destination in
                    Task { try? await draftStore.moveDocument(batchID: batch.id, from: offsets, to: destination) }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button {
                    draftStore.nextScanTarget = .newDocument(batchID: batch.id)
                    showingScanSetup = true
                } label: { Image(systemName: "plus") }
                    .help("New document")
                    .accessibilityLabel("New document")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button {
                    guard let documentID = selectedDocumentID else { return }
                    deletion = .document(batchID: batch.id, documentID: documentID)
                } label: { Image(systemName: "minus") }
                    .help("Remove document")
                    .accessibilityLabel("Remove document")
                    .disabled(
                        selectedDocumentID == nil
                            || isReadOnly
                            || selectedDocument(in: batch)?.transfer.confirmed == true
                    )
                Spacer()
            }
            .padding(8)
        }
    }

    private func pageSidebar(batch: DraftBatch) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAGES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let document = selectedDocument(in: batch) {
                    Text("\(document.pages.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)

            if let document = selectedDocument(in: batch) {
                List(selection: $selectedPageID) {
                    ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnailRow(
                            batchID: batch.id,
                            documentID: document.id,
                            page: page,
                            number: index + 1
                        )
                        .tag(Optional(page.id))
                        .moveDisabled(document.transfer.confirmed || isReadOnly)
                    }
                    .onMove { offsets, destination in
                        Task {
                            try? await draftStore.movePage(
                                batchID: batch.id,
                                documentID: document.id,
                                from: offsets,
                                to: destination
                            )
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }

            Divider()
            HStack {
                Button {
                    requestAddPages(batch: batch)
                } label: { Image(systemName: "doc.badge.plus") }
                    .help("Add pages")
                    .accessibilityLabel("Add pages")
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(
                        selectedDocumentID == nil
                            || isReadOnly
                            || selectedDocument(in: batch)?.transfer.confirmed == true
                    )
                Button {
                    guard let documentID = selectedDocumentID, let pageID = selectedPageID else { return }
                    deletion = .page(batchID: batch.id, documentID: documentID, pageID: pageID)
                } label: { Image(systemName: "trash") }
                    .help("Delete page")
                    .accessibilityLabel("Delete page")
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(
                        selectedPageID == nil
                            || isReadOnly
                            || selectedDocument(in: batch)?.transfer.confirmed == true
                    )
                Spacer()
            }
            .padding(8)
        }
    }

    private func previewWorkspace(batch: DraftBatch) -> some View {
        VStack(spacing: 0) {
            if let document = selectedDocument(in: batch), let page = selectedPage(in: document) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    GeometryReader { proxy in
                        ScrollView([.horizontal, .vertical]) {
                            DraftPageImage(
                                batchID: batch.id,
                                documentID: document.id,
                                page: page
                            )
                            .rotationEffect(.degrees(Double(page.rotation.rawValue)))
                            .frame(
                                width: imageWidth(page: page, container: proxy.size),
                                height: imageHeight(page: page, container: proxy.size)
                            )
                            .padding(32)
                        }
                    }
                }

                Divider()
                pageToolbar(batch: batch, document: document, page: page)
                Divider()
                documentInspector(batch: batch, document: document, page: page)
                    .frame(maxHeight: 190)
            } else {
                ContentUnavailableView("No Page Selected", systemImage: "doc")
            }
        }
    }

    private func pageToolbar(batch: DraftBatch, document: DraftDocument, page: DraftPage) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { try? await draftStore.rotatePage(batchID: batch.id, documentID: document.id, pageID: page.id, clockwise: false) }
            } label: { Image(systemName: "rotate.left") }
                .help("Rotate left")
                .accessibilityLabel("Rotate left")
                .keyboardShortcut("[", modifiers: .command)
                .disabled(isReadOnly || document.transfer.confirmed)
            Button {
                Task { try? await draftStore.rotatePage(batchID: batch.id, documentID: document.id, pageID: page.id, clockwise: true) }
            } label: { Image(systemName: "rotate.right") }
                .help("Rotate right")
                .accessibilityLabel("Rotate right")
                .keyboardShortcut("]", modifiers: .command)
                .disabled(isReadOnly || document.transfer.confirmed)
            Divider().frame(height: 18)
            Button { zoom = max(zoom - 0.1, 0.25); fitMode = .custom } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out")
            Slider(value: $zoom, in: 0.25...3, step: 0.05)
                .frame(width: 120)
                .onChange(of: zoom) { _, _ in fitMode = .custom }
                .accessibilityLabel("Zoom")
                .accessibilityValue(String(localized: "\(Int(zoom * 100)) percent"))
            Button { zoom = min(zoom + 0.1, 3); fitMode = .custom } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in")
            Button("Actual Size") { zoom = 1; fitMode = .actual }
            Button("Fit Page") { fitMode = .page }
            Button("Fit Width") { fitMode = .width }
            Spacer()
            Text("Page \((document.pages.firstIndex(where: { $0.id == page.id }) ?? 0) + 1) of \(document.pages.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func documentInspector(batch: DraftBatch, document: DraftDocument, page: DraftPage) -> some View {
        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("Document name", text: Binding(
                        get: { document.name },
                        set: { newName in
                            Task { try? await draftStore.renameDocument(batchID: batch.id, documentID: document.id, name: newName) }
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .disabled(isReadOnly || document.transfer.confirmed)

                    let settings = page.scanSettings ?? document.scanSettings
                    Label("\(settings.scannerName) · \(settings.source.title)", systemImage: "scanner")
                    Text("\(settings.duplex ? "Duplex" : "Single-sided") · \(settings.colorMode.title) · \(settings.resolution) dpi")
                    Text("Estimated source size: \(ByteCountFormatter.string(fromByteCount: document.pages.reduce(0) { $0 + $1.originalByteCount }, countStyle: .file))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 310, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    Picker("Output", selection: Binding(
                        get: { document.outputFormat },
                        set: { format in
                            Task {
                                do { try await draftStore.setOutputFormat(batchID: batch.id, documentID: document.id, format: format) }
                                catch { operationMessage = error.localizedDescription }
                            }
                        }
                    )) {
                        ForEach(DocumentOutputFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(isReadOnly || document.transfer.confirmed)

                    Picker("Compression", selection: Binding(
                        get: { document.compressionPreset },
                        set: { preset in
                            Task { try? await draftStore.setCompressionPreset(batchID: batch.id, documentID: document.id, preset: preset) }
                        }
                    )) {
                        Text("Original Quality").tag(Optional<OutputCompressionPreset>.none)
                        ForEach(OutputCompressionPreset.allCases) { preset in
                            Text(preset.title).tag(Optional(preset))
                        }
                    }
                    .disabled(isReadOnly || document.transfer.confirmed)
                    if let preset = document.compressionPreset {
                        Text("\(preset.detail). Estimated output: \(formattedEstimatedSize(document))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Estimated output: \(formattedEstimatedSize(document))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    metadataFields(batch: batch, document: document)
                        .disabled(isReadOnly || document.transfer.confirmed)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func metadataFields(batch: DraftBatch, document: DraftDocument) -> some View {
        if let destination = selectedDestination {
            ForEach(destination.parameters.filter { $0.enabled && $0.valueSource == .userEntered }) { parameter in
                if parameter.sensitive {
                    SecureField(
                        parameter.label ?? parameter.name,
                        text: metadataBinding(parameter, batch: batch, document: document)
                    )
                } else if parameter.dataType == .choice {
                    Picker(parameter.label ?? parameter.name, selection: metadataBinding(parameter, batch: batch, document: document)) {
                        if !parameter.required { Text("None").tag("") }
                        ForEach(parameter.allowedValues, id: \.self) { Text($0).tag($0) }
                    }
                } else if parameter.dataType == .boolean {
                    Toggle(parameter.label ?? parameter.name, isOn: Binding(
                        get: { ["true", "1", "yes"].contains(metadataValue(parameter, batch: batch, document: document).lowercased()) },
                        set: { metadataBinding(parameter, batch: batch, document: document).wrappedValue = $0 ? "true" : "false" }
                    ))
                } else {
                    TextField(
                        parameter.label ?? parameter.name,
                        text: metadataBinding(parameter, batch: batch, document: document),
                        prompt: parameter.helpText.map(Text.init)
                    )
                }
                if let issue = DestinationParameterValidator.validate(
                    value: metadataValue(parameter, batch: batch, document: document),
                    for: parameter
                ) {
                    Text(issue).font(.caption).foregroundStyle(.red)
                } else if let help = parameter.helpText, !help.isEmpty {
                    Text(help).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metadataValue(
        _ parameter: DestinationParameter,
        batch: DraftBatch,
        document: DraftDocument
    ) -> String {
        let key = ParameterValueKey(
            parameterID: parameter.id,
            documentID: parameter.scope == .document ? document.id : nil
        )
        if parameter.sensitive {
            return sensitiveMetadata[key]
                ?? (parameter.rememberValue ? selectedDestination.flatMap {
                    destinationStore.rememberedParameterValue(profileID: $0.id, parameterID: parameter.id)
                } : nil)
                ?? parameter.defaultValue
                ?? ""
        }
        if !parameter.rememberValue { return ephemeralMetadata[key, default: parameter.defaultValue ?? ""] }
        let stored = parameter.scope == .document
            ? document.metadata[parameter.name]
            : batch.metadata[parameter.name]
        return stored
            ?? selectedDestination.flatMap {
                destinationStore.rememberedParameterValue(profileID: $0.id, parameterID: parameter.id)
            }
            ?? parameter.defaultValue
            ?? ""
    }

    private func metadataBinding(
        _ parameter: DestinationParameter,
        batch: DraftBatch,
        document: DraftDocument
    ) -> Binding<String> {
        Binding(
            get: { metadataValue(parameter, batch: batch, document: document) },
            set: { value in
                let key = ParameterValueKey(
                    parameterID: parameter.id,
                    documentID: parameter.scope == .document ? document.id : nil
                )
                if parameter.sensitive {
                    sensitiveMetadata[key] = value
                    if parameter.rememberValue, let destination = selectedDestination {
                        try? destinationStore.setRememberedParameterValue(
                            value,
                            profileID: destination.id,
                            parameterID: parameter.id
                        )
                    }
                } else if !parameter.rememberValue {
                    ephemeralMetadata[key] = value
                } else {
                    if let destination = selectedDestination {
                        try? destinationStore.setRememberedParameterValue(
                            value,
                            profileID: destination.id,
                            parameterID: parameter.id
                        )
                    }
                    Task {
                        try? await draftStore.setMetadata(
                            batchID: batch.id,
                            documentID: parameter.scope == .document ? document.id : nil,
                            key: parameter.name,
                            value: value
                        )
                    }
                }
            }
        )
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("No Drafts", systemImage: "doc.viewfinder")
        } description: {
            Text("Scan a document or configure a watched folder to begin.")
        } actions: {
            Button("Scan New Document") {
                draftStore.nextScanTarget = .newBatch
                showingScanSetup = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftStore.actionableCount >= 20)
            .accessibilityIdentifier("scan.new")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            if hasAuthenticationFailure {
                HStack {
                    Label("The destination rejected authentication. Update the Keychain credential and test the connection again.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Destination Settings…") { openSettings() }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            if let conflict = destinationConflicts.first {
                HStack {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    if hasEstimatedSizeConflict {
                        Button("Size Options…") { showingSizeOptions = true }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }
            HStack {
                Button("Scan") {
                    draftStore.nextScanTarget = .newBatch
                    showingScanSetup = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(draftStore.actionableCount >= 20)
                .accessibilityIdentifier("scan.new")

                if let batch = draftStore.selectedBatch, selectedDocumentID != nil {
                    Button("Add Pages") {
                        requestAddPages(batch: batch)
                    }
                    .disabled(isReadOnly || selectedDocument(in: batch)?.transfer.confirmed == true)
                    Button("Rescan") {
                        rescanSelectedDocument()
                    }
                    .disabled(isReadOnly || selectedDocument(in: batch)?.transfer.confirmed == true)
                }

                Menu("Save Copy…") {
                    Button("Selected Document…") { saveCopy(documentID: selectedDocumentID) }
                        .disabled(
                            selectedDocumentID == nil
                                || (draftStore.selectedBatch.flatMap { selectedDocument(in: $0) }?.transfer.confirmed == true
                                    && draftStore.selectedBatch?.isStoredInLibrary != true)
                        )
                    Button("Complete Batch…") { saveCopy() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(isReadOnly && draftStore.selectedBatch?.isStoredInLibrary != true)

                if let batch = draftStore.selectedBatch {
                    if batch.isStoredInLibrary {
                        Label("In Library", systemImage: "books.vertical.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task {
                                do { try await draftStore.setStoredInLibrary(true, batchID: batch.id) }
                                catch { operationMessage = error.localizedDescription }
                            }
                        } label: {
                            Label("Keep in Library", systemImage: "books.vertical")
                        }
                    }
                }

                Button("Discard…", role: .destructive) {
                    if let id = draftStore.selectedBatch?.id { deletion = .batch(batchID: id) }
                }
                .disabled(draftStore.selectedBatch == nil || isReadOnly)

                Spacer()

                if !destinationStore.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Destination", selection: $destinationStore.selectedDestinationID) {
                            ForEach(destinationStore.profiles) { Text($0.displayName).tag(Optional($0.id)) }
                        }
                        if let host = selectedDestination?.host {
                            Text(host)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityLabel(String(localized: "Destination host: \(host)"))
                        }
                    }
                    .frame(width: 210)
                }

                if uploadCoordinator.activity.isBusy {
                    ProgressView(value: uploadProgress)
                        .frame(width: 100)
                    Button("Cancel", role: .cancel) { uploadCoordinator.cancel() }
                        .accessibilityIdentifier("upload.cancel")
                } else if draftStore.selectedBatch?.state == .sent {
                    Button("Send Again as New Copy", action: duplicateForSendAgain)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("draft.send-again")
                } else {
                    Button(sendButtonTitle, action: requestSend)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .accessibilityIdentifier("draft.send")
                }
            }
            .padding(14)
        }
    }

    private var selectedDestination: DestinationProfile? {
        destinationStore.profile(id: destinationStore.selectedDestinationID ?? destinationStore.defaultDestinationID)
    }

    private var hasAuthenticationFailure: Bool {
        draftStore.selectedBatch?.documents.contains {
            $0.transfer.lastStatusCode == 401 || $0.transfer.lastStatusCode == 403
        } == true
    }

    private var destinationConflicts: [String] {
        guard let batch = draftStore.selectedBatch else { return [] }
        guard let destination = selectedDestination else {
            return [String(localized: "Choose or create an upload destination.")]
        }
        var messages = destinationStore.validationIssues(for: destination)
            .filter { $0.severity == .error }.map(\.message)
        if batch.lastErrorCategory == "output_size_exceeded" {
            messages.append(String(localized: "The generated output exceeded a destination size limit. Choose Size Options, save a copy, or rescan at lower resolution."))
        }
        if !destination.enabled {
            messages.append(String(localized: "Enable this destination before sending."))
        }
        let outboundDocumentCount = destination.projectedOutboundDocumentCount(
            pageCounts: batch.documents.filter { !$0.transfer.confirmed }.map { $0.pages.count }
        )
        if destination.batchPolicy == .oneDocument && outboundDocumentCount > 1 {
            messages.append(String(localized: "This destination accepts one document per send."))
        }
        if outboundDocumentCount > destination.maximumDocumentsPerBatch {
            if destination.pagePolicy == .singlePage, destination.singlePageOverflow != .reject {
                messages.append(String(localized: "The single-page policy would create \(outboundDocumentCount) outbound documents, exceeding the destination’s document limit."))
            } else {
                messages.append(String(localized: "This batch exceeds the destination’s document limit."))
            }
        }
        for document in batch.documents where !document.transfer.confirmed {
            if destination.pagePolicy == .singlePage,
               destination.singlePageOverflow == .reject,
               document.pages.count > 1 {
                messages.append(String(localized: "\(document.name) has more than one page."))
            }
            if let maximum = destination.maximumPagesPerDocument, document.pages.count > maximum {
                messages.append(String(localized: "\(document.name) exceeds the page limit."))
            }
            if !destination.acceptedOutputFormats.contains(document.outputFormat) {
                messages.append(String(localized: "The destination does not accept \(document.outputFormat.title)."))
            }
            if let maximum = destination.maximumFileBytes, estimatedOutputBytes(document) > maximum {
                messages.append(String(localized: "\(document.name) is estimated to exceed the file-size limit."))
            }
            for parameter in destination.parameters where parameter.enabled && parameter.valueSource == .userEntered {
                let value = metadataValue(parameter, batch: batch, document: document)
                if let issue = DestinationParameterValidator.validate(value: value, for: parameter) {
                    messages.append(issue)
                }
            }
        }
        if let maximum = destination.maximumBatchBytes,
           batch.documents.filter({ !$0.transfer.confirmed }).reduce(Int64(0), { $0 + estimatedOutputBytes($1) }) > maximum {
            messages.append(String(localized: "This batch is estimated to exceed the destination’s total-size limit."))
        }
        return Array(Set(messages)).sorted()
    }

    private var hasEstimatedSizeConflict: Bool {
        guard let batch = draftStore.selectedBatch, let destination = selectedDestination else { return false }
        if batch.lastErrorCategory == "output_size_exceeded" { return true }
        if let maximum = destination.maximumFileBytes,
           batch.documents.contains(where: { !$0.transfer.confirmed && estimatedOutputBytes($0) > maximum }) {
            return true
        }
        let total = batch.documents.filter { !$0.transfer.confirmed }.reduce(Int64(0)) { $0 + estimatedOutputBytes($1) }
        return destination.maximumBatchBytes.map { total > $0 } ?? false
    }

    private func estimatedOutputBytes(_ document: DraftDocument) -> Int64 {
        let source = document.pages.reduce(Int64(0)) { $0 + $1.originalByteCount }
        return Int64(Double(source) * (document.compressionPreset?.estimatedSizeRatio ?? 1))
    }

    private func formattedEstimatedSize(_ document: DraftDocument) -> String {
        ByteCountFormatter.string(fromByteCount: estimatedOutputBytes(document), countStyle: .file)
    }

    private var compressionOptionsMessage: String {
        guard let batch = draftStore.selectedBatch else {
            return String(localized: "Choose the resulting quality explicitly. Encrypted source pages remain unchanged.")
        }
        let sourceBytes = batch.documents
            .filter { !$0.transfer.confirmed }
            .flatMap(\.pages)
            .reduce(Int64(0)) { $0 + $1.originalByteCount }
        let balancedBytes = Int64(Double(sourceBytes) * OutputCompressionPreset.balanced.estimatedSizeRatio)
        let smallerBytes = Int64(Double(sourceBytes) * OutputCompressionPreset.smaller.estimatedSizeRatio)
        let balancedSize = ByteCountFormatter.string(fromByteCount: balancedBytes, countStyle: .file)
        let smallerSize = ByteCountFormatter.string(fromByteCount: smallerBytes, countStyle: .file)
        return String(localized: "Balanced: about \(balancedSize), \(OutputCompressionPreset.balanced.detail). Smaller File: about \(smallerSize), \(OutputCompressionPreset.smaller.detail). Encrypted source pages remain unchanged.")
    }

    private var canSend: Bool {
        guard let batch = draftStore.selectedBatch, batch.pageCount > 0 else { return false }
        return destinationConflicts.isEmpty && !scannerService.activity.isBusy && !uploadCoordinator.activity.isBusy && !isReadOnly
    }

    private var isReadOnly: Bool {
        guard let batch = draftStore.selectedBatch else { return false }
        return batch.state == .uploading || batch.state == .preparing || batch.state == .sent
    }

    private var sendButtonTitle: String {
        (draftStore.selectedBatch?.actionableDocumentCount ?? 0) > 1
            ? String(localized: "Send All")
            : String(localized: "Send")
    }

    private var uploadProgress: Double {
        if case let .uploading(progress) = uploadCoordinator.activity { return progress }
        return 0
    }

    private var statusText: String {
        if uploadCoordinator.activeBatchID == draftStore.selectedBatchID {
            switch uploadCoordinator.activity {
            case .idle: break
            case .preparing: return String(localized: "Preparing output…")
            case let .uploading(progress): return String(localized: "Uploading \(Int(progress * 100))%")
            case let .waitingToRetry(attempt, seconds): return String(localized: "Retry \(attempt) in \(seconds) seconds")
            case .waitingForNetwork: return String(localized: "Waiting for network")
            case let .completed(message), let .failed(message): return message
            case .cancelled: return String(localized: "Upload cancelled; draft preserved")
            }
        }
        return draftStore.selectedBatch?.state.title ?? scannerService.activity.label
    }

    private var statusSymbol: String {
        switch draftStore.selectedBatch?.state {
        case .sent: "checkmark.circle.fill"
        case .failed, .interrupted, .partiallySent: "exclamationmark.triangle.fill"
        case .uploading, .preparing: "arrow.up.circle.fill"
        default: "doc.text"
        }
    }

    private var statusColor: Color {
        switch draftStore.selectedBatch?.state {
        case .sent: .green
        case .failed, .interrupted, .partiallySent: .orange
        default: .accentColor
        }
    }

    private func selectedDocument(in batch: DraftBatch) -> DraftDocument? {
        batch.documents.first { $0.id == selectedDocumentID } ?? batch.documents.first
    }

    private func selectedPage(in document: DraftDocument) -> DraftPage? {
        document.pages.first { $0.id == selectedPageID } ?? document.pages.first
    }

    private func normalizeSelection() {
        guard let batch = draftStore.selectedBatch else {
            selectedDocumentID = nil
            selectedPageID = nil
            return
        }
        if !batch.documents.contains(where: { $0.id == selectedDocumentID }) {
            selectedDocumentID = batch.documents.first?.id
        }
        if let document = selectedDocument(in: batch), !document.pages.contains(where: { $0.id == selectedPageID }) {
            selectedPageID = document.pages.first?.id
        }
    }

    private func restoreDestinationForSelectedBatch() {
        guard let destinationID = draftStore.selectedBatch?.destinationID,
              destinationStore.profile(id: destinationID) != nil else { return }
        destinationStore.selectedDestinationID = destinationID
    }

    private func simplePageReferences(in batch: DraftBatch) -> [(documentID: UUID, pageID: UUID)] {
        batch.documents.flatMap { document in
            document.pages.map { page in (documentID: document.id, pageID: page.id) }
        }
    }

    private func simplePageIndex(in references: [(documentID: UUID, pageID: UUID)]) -> Int {
        references.firstIndex {
            $0.documentID == selectedDocumentID && $0.pageID == selectedPageID
        } ?? 0
    }

    private func moveSimplePage(by offset: Int, in batch: DraftBatch) {
        let references = simplePageReferences(in: batch)
        guard !references.isEmpty else { return }
        let nextIndex = min(max(simplePageIndex(in: references) + offset, 0), references.count - 1)
        selectedDocumentID = references[nextIndex].documentID
        selectedPageID = references[nextIndex].pageID
    }

    private func simpleFittedImageSize(page: DraftPage, container: CGSize) -> CGSize {
        let rotated = page.rotation == .clockwise90 || page.rotation == .counterClockwise90
        let naturalWidth = CGFloat(rotated ? page.physicalHeightPoints : page.physicalWidthPoints)
        let naturalHeight = CGFloat(rotated ? page.physicalWidthPoints : page.physicalHeightPoints)
        let availableWidth = max(container.width - 64, 100)
        let availableHeight = max(container.height - 64, 100)
        let scale = min(availableWidth / max(naturalWidth, 1), availableHeight / max(naturalHeight, 1))
        return CGSize(width: naturalWidth * max(scale, 0.1), height: naturalHeight * max(scale, 0.1))
    }

    private func imageWidth(page: DraftPage, container: CGSize) -> CGFloat {
        let rotated = page.rotation == .clockwise90 || page.rotation == .counterClockwise90
        let naturalWidth = CGFloat(rotated ? page.physicalHeightPoints : page.physicalWidthPoints)
        let naturalHeight = CGFloat(rotated ? page.physicalWidthPoints : page.physicalHeightPoints)
        switch fitMode {
        case .actual, .custom: return naturalWidth * CGFloat(zoom)
        case .page:
            let scale = min((container.width - 64) / max(naturalWidth, 1), (container.height - 64) / max(naturalHeight, 1))
            return naturalWidth * max(scale, 0.1)
        case .width: return max(container.width - 64, 100)
        }
    }

    private func imageHeight(page: DraftPage, container: CGSize) -> CGFloat {
        let rotated = page.rotation == .clockwise90 || page.rotation == .counterClockwise90
        let naturalWidth = CGFloat(rotated ? page.physicalHeightPoints : page.physicalWidthPoints)
        let naturalHeight = CGFloat(rotated ? page.physicalWidthPoints : page.physicalHeightPoints)
        let width = imageWidth(page: page, container: container)
        return width * naturalHeight / max(naturalWidth, 1)
    }

    private func send() {
        guard let batchID = draftStore.selectedBatch?.id,
              let destinationID = selectedDestination?.id else { return }
        uploadCoordinator.startSend(
            batchID: batchID,
            destinationID: destinationID,
            ephemeralParameterSecrets: sensitiveMetadata.merging(ephemeralMetadata) { secret, _ in secret }
        )
    }

    private func requestSend() {
        if destinationHostChange != nil {
            confirmDestinationHostChange = true
            return
        }
        continueSendChecks()
    }

    private func requestAddPages(batch: DraftBatch) {
        guard let documentID = selectedDocumentID,
              let document = batch.documents.first(where: { $0.id == documentID }) else { return }
        if document.transfer.confirmed {
            operationMessage = DraftStoreError.confirmedDocumentReadOnly.localizedDescription
            return
        }
        switch selectedDestination?.additionalPageDecision(currentPageCount: document.pages.count)
            ?? .appendToCurrentDocument {
        case .maximumPagesReached(let maximum):
            operationMessage = String(localized: "This document has reached the destination’s \(maximum)-page limit. Start a new document instead; the existing pages remain safe.")
        case .appendToCurrentDocument:
            draftStore.nextScanTarget = .appendPages(batchID: batch.id, documentID: documentID)
            showingScanSetup = true
        case .startNewDocument:
            startNewDocumentScan()
        case .askToStartNewDocument:
            confirmAddPagesAsNewDocument = true
        case .rejectSinglePage:
            operationMessage = String(localized: "This destination permits one page per document. Start a new document to scan another page; the existing page remains safe.")
        }
    }

    private func startNewDocumentScan() {
        guard let batchID = draftStore.selectedBatch?.id else { return }
        draftStore.nextScanTarget = .newDocument(batchID: batchID)
        showingScanSetup = true
    }

    private func continueSendChecks() {
        guard let batch = draftStore.selectedBatch else { return }
        if requiresSinglePageSplit, let destination = selectedDestination {
            if destination.singlePageOverflow == .ask {
                confirmSinglePageSplit = true
            } else {
                splitSinglePageDocumentsAndSend()
            }
            return
        }
        if batch.lastErrorCategory == "ambiguous_transmission",
           selectedDestination?.receiverSupportsIdempotency == false {
            confirmAmbiguousRetry = true
        } else {
            send()
        }
    }

    private var destinationHostChange: (oldHost: String, newHost: String)? {
        guard let batch = draftStore.selectedBatch,
              let previousID = batch.destinationID,
              let oldHost = destinationStore.profile(id: previousID)?.host,
              let newHost = selectedDestination?.host,
              oldHost.caseInsensitiveCompare(newHost) != .orderedSame else { return nil }
        return (oldHost, newHost)
    }

    private var requiresSinglePageSplit: Bool {
        guard let batch = draftStore.selectedBatch,
              let destination = selectedDestination,
              destination.pagePolicy == .singlePage,
              destination.singlePageOverflow != .reject else { return false }
        return batch.documents.contains { !$0.transfer.confirmed && $0.pages.count > 1 }
    }

    private func splitSinglePageDocumentsAndSend() {
        guard let batchID = draftStore.selectedBatch?.id else { return }
        Task {
            do {
                let mapping = try await draftStore.splitDocumentsIntoSinglePages(batchID: batchID)
                replicateEphemeralDocumentValues(using: mapping)
                send()
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func replicateEphemeralDocumentValues(using mapping: [UUID: [UUID]]) {
        func expanded(_ source: [ParameterValueKey: String]) -> [ParameterValueKey: String] {
            var result = source
            for (key, value) in source {
                guard let oldDocumentID = key.documentID,
                      let newDocumentIDs = mapping[oldDocumentID] else { continue }
                for documentID in newDocumentIDs {
                    result[ParameterValueKey(parameterID: key.parameterID, documentID: documentID)] = value
                }
            }
            return result
        }
        sensitiveMetadata = expanded(sensitiveMetadata)
        ephemeralMetadata = expanded(ephemeralMetadata)
    }

    private func duplicateForSendAgain() {
        guard let batchID = draftStore.selectedBatch?.id else { return }
        Task {
            do { try await draftStore.duplicateForSendAgain(batchID: batchID) }
            catch { operationMessage = error.localizedDescription }
        }
    }

    private func applyCompressionPreset(_ preset: OutputCompressionPreset) {
        guard let batch = draftStore.selectedBatch else { return }
        Task {
            for document in batch.documents where !document.transfer.confirmed {
                try? await draftStore.setCompressionPreset(batchID: batch.id, documentID: document.id, preset: preset)
            }
        }
    }

    private func rescanSelectedDocument() {
        guard let batchID = draftStore.selectedBatch?.id, let documentID = selectedDocumentID else { return }
        if draftStore.selectedBatch?.documents.first(where: { $0.id == documentID })?.transfer.confirmed == true {
            operationMessage = DraftStoreError.confirmedDocumentReadOnly.localizedDescription
            return
        }
        draftStore.nextScanTarget = .replaceDocument(batchID: batchID, documentID: documentID)
        showingScanSetup = true
    }

    private func saveCopy(documentID: UUID? = nil) {
        guard let batch = draftStore.selectedBatch else { return }
        Task {
            do {
                let outputs = try await draftStore.prepareOutputs(
                    batchID: batch.id,
                    documentIDs: documentID.map { Set([$0]) },
                    includeConfirmed: batch.isStoredInLibrary
                )
                defer { Task { await draftStore.cleanupPreparedOutputs(outputs) } }
                guard !outputs.isEmpty else {
                    operationMessage = String(localized: "No document is available to save. Keep a local library copy before exporting a sent batch.")
                    return
                }
                if outputs.count == 1, let output = outputs.first {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = output.filename
                    guard panel.runModal() == .OK, let target = panel.url else { return }
                    try FileManager.default.copyItem(at: output.fileURL, to: target)
                } else {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = String(localized: "Save Here")
                    guard panel.runModal() == .OK, let directory = panel.url else { return }
                    for output in outputs {
                        try FileManager.default.copyItem(
                            at: output.fileURL,
                            to: directory.appendingPathComponent(output.filename)
                        )
                    }
                }
                operationMessage = String(localized: "A copy was saved successfully.")
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func performDeletion() {
        guard let deletion else { return }
        self.deletion = nil
        Task {
            do {
                switch deletion {
                case let .page(batchID, documentID, pageID):
                    try await draftStore.deletePage(batchID: batchID, documentID: documentID, pageID: pageID)
                case let .document(batchID, documentID):
                    try await draftStore.deleteDocument(batchID: batchID, documentID: documentID)
                case let .batch(batchID):
                    try await draftStore.discardBatch(batchID)
                }
                normalizeSelection()
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }
}

private enum PreviewFitMode: String { case actual, page, width, custom }

private enum DeletionRequest: Identifiable {
    case page(batchID: UUID, documentID: UUID, pageID: UUID)
    case document(batchID: UUID, documentID: UUID)
    case batch(batchID: UUID)

    var id: String { String(describing: self) }
    var title: String {
        switch self {
        case .page: String(localized: "Delete this page?")
        case .document: String(localized: "Remove this document?")
        case .batch: String(localized: "Discard this entire draft?")
        }
    }
    var buttonTitle: String {
        switch self {
        case .page: String(localized: "Delete Page")
        case .document: String(localized: "Remove Document")
        case .batch: String(localized: "Discard Draft")
        }
    }
    var message: String {
        String(localized: "The encrypted local copy will be removed. This cannot be undone.")
    }
}

private struct DocumentRow: View {
    let index: Int
    let document: DraftDocument
    let uploadActivity: DocumentUploadActivity?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                Text(document.name).lineLimit(1)
            }
            Text("Document \(index + 1) · \(document.pages.count) page\(document.pages.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let statusText {
                Text(statusText).font(.caption2).foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            document.pages.count == 1
                ? String(localized: "Document \(index + 1), \(document.name), 1 page")
                : String(localized: "Document \(index + 1), \(document.name), \(document.pages.count) pages")
        )
        .accessibilityValue(statusText ?? (document.transfer.confirmed ? String(localized: "Confirmed") : String(localized: "Ready")))
    }

    private var statusSymbol: String {
        if document.transfer.confirmed { return "checkmark.circle.fill" }
        return switch uploadActivity {
        case .queued: "clock"
        case .uploading: "arrow.up.circle.fill"
        case .waitingToRetry: "clock.arrow.circlepath"
        case .confirmed: "checkmark.circle.fill"
        case .unconfirmed, .failed: "exclamationmark.triangle.fill"
        case nil: "doc"
        }
    }

    private var statusColor: Color {
        if document.transfer.confirmed { return .green }
        return switch uploadActivity {
        case .confirmed: .green
        case .unconfirmed, .failed: .orange
        case .uploading: .accentColor
        default: .secondary
        }
    }

    private var statusText: String? {
        return switch uploadActivity {
        case .queued: String(localized: "Queued")
        case let .uploading(progress): String(localized: "Uploading \(Int(progress * 100))%")
        case let .waitingToRetry(attempt, seconds): String(localized: "Retry \(attempt) in \(seconds) seconds")
        case .confirmed: String(localized: "Confirmed")
        case let .unconfirmed(message): message ?? String(localized: "Not confirmed")
        case let .failed(message): message
        case nil: nil
        }
    }
}

private struct PageThumbnailRow: View {
    let batchID: UUID
    let documentID: UUID
    let page: DraftPage
    let number: Int

    var body: some View {
        VStack(spacing: 5) {
            DraftPageImage(batchID: batchID, documentID: documentID, page: page)
                .rotationEffect(.degrees(Double(page.rotation.rawValue)))
                .scaledToFit()
                .frame(height: 120)
                .background(.white)
                .overlay { Rectangle().stroke(.quaternary) }
            Text("Page \(number)").font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Page \(number)"))
        .accessibilityValue(
            page.rotation == .zero
                ? String(localized: "Not rotated")
                : String(localized: "Rotated \(page.rotation.rawValue) degrees")
        )
    }
}

private struct DraftPageImage: View {
    @EnvironmentObject private var draftStore: DraftStore
    let batchID: UUID
    let documentID: UUID
    let page: DraftPage

    @State private var image: NSImage?
    @State private var materializedURL: URL?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: page.id) {
            if let materializedURL { await draftStore.releaseMaterializedPage(materializedURL) }
            do {
                let url = try await draftStore.materializePage(batchID: batchID, documentID: documentID, page: page)
                materializedURL = url
                image = NSImage(contentsOf: url)
            } catch { image = nil }
        }
        .onDisappear {
            guard let materializedURL else { return }
            Task { await draftStore.releaseMaterializedPage(materializedURL) }
        }
        .accessibilityLabel("Scanned page")
    }
}

struct ScanAcquisitionView: View {
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var scanDefaultsStore: ScanDefaultsStore
    @EnvironmentObject private var webcamService: WebcamCaptureService
    @Environment(\.dismiss) private var dismiss
    @State private var source: ScanSource = .automatic
    @State private var colorMode: ScanColorMode = .color
    @State private var resolution = 300
    @State private var duplex = true
    @State private var pageSize: ScanPageSize = .automatic
    @State private var orientation: ScanOrientation = .automatic
    @State private var startingBatchUpdate: Date?
    @State private var isApplyingTargetScanner = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Scan Setup", systemImage: "doc.viewfinder").font(.headline)
                Spacer()
                Text(scannerService.activity.label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            Form {
                Picker("Scanner", selection: Binding(
                    get: { scannerService.selectedScannerID },
                    set: { scannerService.selectedScannerID = $0 }
                )) {
                    ForEach(scannerService.scanners) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Source", selection: $source) {
                    ForEach(sourceChoices) { Label($0.title, systemImage: $0.symbolName).tag($0) }
                }
                if source == .automatic,
                   let resolved = scannerService.selectedScanner?.capabilities.resolvedSource(for: .automatic) {
                    LabeledContent("Resolved source", value: resolved.title)
                }
                Picker("Sides", selection: $duplex) {
                    Text("Single-sided").tag(false)
                    Text("Duplex").tag(true)
                }
                .disabled(source == .flatbed || !(scannerService.selectedScanner?.capabilities.supportsDuplex ?? false))
                Picker("Color", selection: $colorMode) {
                    ForEach(ScanColorMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $resolution) {
                    ForEach(resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
                }
                Picker("Page Size", selection: $pageSize) {
                    ForEach(pageSizes) { Text($0.title).tag($0) }
                }
                Picker("Orientation", selection: $orientation) {
                    ForEach(ScanOrientation.allCases) { Text($0.title).tag($0) }
                }
                if let loaded = scannerService.selectedScanner?.capabilities.feederDocumentLoaded, source != .flatbed {
                    Label(loaded ? "Document detected" : "Feeder is empty", systemImage: loaded ? "checkmark.circle" : "tray")
                        .foregroundStyle(loaded ? Color.green : .secondary)
                }
                if newBatchWouldExceedDraftLimit {
                    Label(
                        "The 20-draft limit is reached. Send, save, or discard a draft before starting another scan.",
                        systemImage: "tray.full.fill"
                    )
                    .foregroundStyle(.orange)
                }
                if case .automatic = source,
                   scannerService.selectedScanner?.capabilities.feederDocumentLoaded == nil,
                   scannerService.selectedScanner?.capabilities.availableSources.count ?? 0 > 1 {
                    Text("This scanner cannot report feeder state reliably. Choose Flatbed or Document Feeder explicitly.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            .disabled(scannerService.activity.isBusy)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) {
                    if scannerService.activity.isBusy { scannerService.cancelScan() } else { dismiss() }
                }
                Spacer()
                Button("Scan", action: startScan)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canScan)
                    .accessibilityIdentifier("scan.start")
            }
            .padding(14)
        }
        .frame(width: 480, height: 500)
        .onAppear(perform: loadInitialSettings)
        .onChange(of: scannerService.selectedScannerID) { _, _ in
            if isApplyingTargetScanner {
                isApplyingTargetScanner = false
                normalize()
            } else {
                loadScannerDefaults()
            }
        }
        .onChange(of: source) { _, newSource in
            scannerService.prepareCapabilities(for: newSource)
        }
        .onChange(of: scannerService.selectedScanner?.capabilities) { _, _ in normalize() }
        .onChange(of: draftStore.selectedBatch?.updatedAt) { _, newValue in
            if let startingBatchUpdate, let newValue, newValue > startingBatchUpdate { dismiss() }
        }
    }

    private var sourceChoices: [ScanSource] {
        let choices = scannerService.selectedScanner?.capabilities.sourceChoices ?? []
        return choices.isEmpty ? [.automatic] : choices
    }
    private var resolutions: [Int] {
        scannerService.selectedScanner?.capabilities.resolutions ?? [150, 200, 300, 600]
    }
    private var pageSizes: [ScanPageSize] {
        scannerService.selectedScanner?.capabilities.pageSizes ?? [.automatic]
    }
    private var canScan: Bool {
        guard scannerService.selectedScanner != nil, !scannerService.activity.isBusy else { return false }
        guard !webcamService.isSessionRunning, !webcamService.activity.isBusy else { return false }
        guard !newBatchWouldExceedDraftLimit else { return false }
        if source == .automatic,
           scannerService.selectedScanner?.capabilities.feederDocumentLoaded == nil,
           scannerService.selectedScanner?.capabilities.availableSources.count ?? 0 > 1 { return false }
        return true
    }
    private var newBatchWouldExceedDraftLimit: Bool {
        guard draftStore.actionableCount >= 20 else { return false }
        if case .newBatch = draftStore.nextScanTarget { return true }
        return false
    }
    private func loadInitialSettings() {
        let priorRequest: ScanRequest? = switch draftStore.nextScanTarget {
        case .newBatch:
            nil
        case let .appendPages(batchID, documentID), let .replaceDocument(batchID, documentID):
            draftStore.batches
                .first(where: { $0.id == batchID })?
                .documents.first(where: { $0.id == documentID })
                .map(request(from:))
        case let .newDocument(batchID):
            draftStore.batches
                .first(where: { $0.id == batchID })?
                .documents.last
                .map(request(from:))
        }

        if let priorRequest {
            if scannerService.scanners.contains(where: { $0.id == priorRequest.scannerID }),
               scannerService.selectedScannerID != priorRequest.scannerID {
                isApplyingTargetScanner = true
                scannerService.selectedScannerID = priorRequest.scannerID
            }
            apply(priorRequest)
        } else {
            loadScannerDefaults()
        }
    }
    private func loadScannerDefaults() {
        guard let scannerID = scannerService.selectedScannerID else {
            normalize()
            return
        }
        apply(scanDefaultsStore.request(for: scannerID))
    }
    private func request(from document: DraftDocument) -> ScanRequest {
        let settings = document.pages.last?.scanSettings ?? document.scanSettings
        return ScanRequest(
            scannerID: settings.scannerID,
            source: settings.source,
            colorMode: settings.colorMode,
            resolution: settings.resolution,
            duplex: settings.duplex,
            pageSize: settings.pageSize,
            orientation: settings.orientation
        )
    }
    private func apply(_ request: ScanRequest) {
        source = request.source
        colorMode = request.colorMode
        resolution = request.resolution
        duplex = request.duplex
        pageSize = request.pageSize
        orientation = request.orientation
        normalize()
    }
    private func normalize() {
        if !sourceChoices.contains(source) { source = sourceChoices.first ?? .automatic }
        if !resolutions.contains(resolution) {
            resolution = resolutions.min(by: { abs($0 - 300) < abs($1 - 300) }) ?? 300
        }
        if !pageSizes.contains(pageSize) { pageSize = .automatic }
        if source == .flatbed || !(scannerService.selectedScanner?.capabilities.supportsDuplex ?? false) { duplex = false }
    }
    private func startScan() {
        guard let scannerID = scannerService.selectedScanner?.id else { return }
        startingBatchUpdate = draftStore.selectedBatch?.updatedAt ?? .distantPast
        let request = ScanRequest(
            scannerID: scannerID,
            source: source,
            colorMode: colorMode,
            resolution: resolution,
            duplex: duplex,
            pageSize: pageSize,
            orientation: orientation
        )
        scanDefaultsStore.save(request)
        scannerService.startScan(request)
    }
}
