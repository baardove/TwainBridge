import Foundation

@MainActor
final class WorkspaceRouter: ObservableObject {
    @Published private(set) var scanRequestToken = UUID()
    @Published private(set) var openWorkspaceToken = UUID()
    @Published private(set) var openWebcamToken = UUID()
    @Published private(set) var requestedTarget: DraftInsertionTarget = .newBatch

    func requestScan(target: DraftInsertionTarget = .newBatch) {
        requestedTarget = target
        scanRequestToken = UUID()
    }

    func requestOpenWorkspace() {
        openWorkspaceToken = UUID()
    }

    func requestOpenWebcam() {
        openWebcamToken = UUID()
    }
}
