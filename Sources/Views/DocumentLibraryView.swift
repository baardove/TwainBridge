import AppKit
import SwiftUI

struct DocumentLibraryView: View {
    @EnvironmentObject private var draftStore: DraftStore
    @EnvironmentObject private var destinationStore: DestinationStore
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var selectedBatchID: UUID?
    @State private var removalCandidate: UUID?
    @State private var operationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if draftStore.libraryBatches.isEmpty {
                emptyLibrary
            } else {
                HSplitView {
                    browser
                        .frame(minWidth: 360, idealWidth: 430)
                    detail
                        .frame(minWidth: 460)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { normalizeSelection() }
        .onChange(of: visibleBatches.map(\.id)) { _, _ in normalizeSelection() }
        .confirmationDialog(
            "Remove local library copy?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { removeCandidate() }
            Button("Cancel", role: .cancel) { removalCandidate = nil }
        } message: {
            Text(removalMessage)
        }
        .alert("TwainBridge", isPresented: Binding(
            get: { operationMessage != nil },
            set: { if !$0 { operationMessage = nil } }
        )) {
            Button("OK") { operationMessage = nil }
        } message: {
            Text(operationMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Document Library", systemImage: "books.vertical")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("\(draftStore.libraryBatches.count) items · \(formattedBytes(draftStore.libraryByteCount))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await draftStore.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .padding(16)
    }

    private var browser: some View {
        VStack(spacing: 10) {
            TextField("Search documents", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Picker("Source", selection: $filter) {
                ForEach(LibraryFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            if visibleBatches.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleBatches, selection: $selectedBatchID) { batch in
                    LibraryRow(batch: batch)
                        .environmentObject(draftStore)
                        .tag(batch.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let batch = selectedBatch {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let first = firstPage(in: batch) {
                            LibraryPageImage(
                                batchID: batch.id,
                                documentID: first.documentID,
                                page: first.page
                            )
                            .environmentObject(draftStore)
                            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 430)
                            .padding(20)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Text(batch.documents.first?.name ?? String(localized: "Untitled Document"))
                            .font(.title2.weight(.semibold))

                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
                            detailRow("Source", value: batch.captureOrigin.title)
                            detailRow("Captured", value: batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                            detailRow("Contents", value: String(localized: "\(batch.documents.count) document(s), \(batch.pageCount) page(s)"))
                            detailRow("Local size", value: formattedBytes(batch.originalByteCount))
                            detailRow("Status", value: batch.state.title)
                            if let destination = destinationStore.profile(id: batch.destinationID) {
                                detailRow("Destination", value: destination.displayName)
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                HStack {
                    Button("Remove Local Copy…", role: .destructive) {
                        removalCandidate = batch.id
                    }
                    Spacer()
                    Button("Save Copy…") { saveCopy(batch) }
                    if batch.state == .sent {
                        Button("Send Again") { sendAgain(batch) }
                    }
                    Button(batch.state == .sent ? "Open" : "Open & Send") {
                        openInWorkspace(batch)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView(
                "Select a Document",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a scan or webcam capture to preview and recall it.")
            )
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Saved Documents", systemImage: "books.vertical")
        } description: {
            Text("New scanner documents and webcam captures can be retained here automatically after sending.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleBatches: [DraftBatch] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return draftStore.libraryBatches.filter { batch in
            let matchesFilter = filter.matches(batch.captureOrigin)
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            let searchable = batch.documents.map(\.name).joined(separator: " ")
                + " " + batch.captureOrigin.title + " " + batch.state.title
            return searchable.lowercased().contains(query)
        }
    }

    private var selectedBatch: DraftBatch? {
        guard let selectedBatchID else { return visibleBatches.first }
        return visibleBatches.first { $0.id == selectedBatchID }
    }

    private var removalMessage: String {
        guard let id = removalCandidate,
              let batch = draftStore.batches.first(where: { $0.id == id }) else { return "" }
        if batch.state == .sent {
            return String(localized: "The encrypted local documents will be permanently deleted. This does not delete copies already sent to a website.")
        }
        return String(localized: "This item will leave the library but remain available as an active draft until normal draft retention removes it.")
    }

    @ViewBuilder
    private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func firstPage(in batch: DraftBatch) -> (documentID: UUID, page: DraftPage)? {
        guard let document = batch.documents.first(where: { !$0.pages.isEmpty }),
              let page = document.pages.first else { return nil }
        return (document.id, page)
    }

    private func normalizeSelection() {
        if selectedBatch == nil { selectedBatchID = visibleBatches.first?.id }
    }

    private func openInWorkspace(_ batch: DraftBatch) {
        draftStore.selectedBatchID = batch.id
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sendAgain(_ batch: DraftBatch) {
        Task {
            do {
                let copy = try await draftStore.duplicateForSendAgain(batchID: batch.id)
                openInWorkspace(copy)
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func removeCandidate() {
        guard let id = removalCandidate else { return }
        removalCandidate = nil
        Task {
            do { try await draftStore.removeFromLibrary(batchID: id) }
            catch { operationMessage = error.localizedDescription }
        }
    }

    private func saveCopy(_ batch: DraftBatch) {
        Task {
            do {
                let outputs = try await draftStore.prepareOutputs(
                    batchID: batch.id,
                    includeConfirmed: true
                )
                defer { Task { await draftStore.cleanupPreparedOutputs(outputs) } }
                guard !outputs.isEmpty else {
                    operationMessage = String(localized: "This library item has no document to export.")
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
            } catch {
                operationMessage = error.localizedDescription
            }
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case scanner
    case webcam
    case watchedFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .scanner: String(localized: "Scans")
        case .webcam: String(localized: "Webcam")
        case .watchedFolder: String(localized: "Folder")
        }
    }

    func matches(_ origin: DocumentCaptureOrigin) -> Bool {
        switch self {
        case .all: true
        case .scanner: origin == .scanner || origin == .mixed
        case .webcam: origin == .webcam || origin == .mixed
        case .watchedFolder: origin == .watchedFolder || origin == .mixed
        }
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var draftStore: DraftStore
    let batch: DraftBatch

    var body: some View {
        HStack(spacing: 12) {
            if let document = batch.documents.first(where: { !$0.pages.isEmpty }),
               let page = document.pages.first {
                LibraryPageImage(batchID: batch.id, documentID: document.id, page: page)
                    .environmentObject(draftStore)
                    .frame(width: 58, height: 70)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(.quaternary) }
            } else {
                Image(systemName: "doc")
                    .frame(width: 58, height: 70)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(batch.documents.first?.name ?? String(localized: "Untitled Document"))
                    .font(.headline)
                    .lineLimit(1)
                Label(batch.captureOrigin.title, systemImage: batch.captureOrigin.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("\(batch.documents.count) doc · \(batch.pageCount) pg")
                    Spacer()
                    Text(batch.createdAt, style: .date)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryPageImage: View {
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
                let url = try await draftStore.materializePage(
                    batchID: batchID,
                    documentID: documentID,
                    page: page
                )
                materializedURL = url
                image = NSImage(contentsOf: url)
            } catch {
                image = nil
            }
        }
        .onDisappear {
            guard let materializedURL else { return }
            Task { await draftStore.releaseMaterializedPage(materializedURL) }
        }
        .accessibilityLabel("Document preview")
    }
}
