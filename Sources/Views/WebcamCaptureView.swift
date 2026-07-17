@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct WebcamCaptureView: View {
    @EnvironmentObject private var webcamService: WebcamCaptureService
    @EnvironmentObject private var scannerService: ScannerService
    @EnvironmentObject private var draftStore: DraftStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Webcam Capture").font(.title2.bold())
                    Text("Position the document inside the preview, then capture one photo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !webcamService.cameras.isEmpty {
                    Picker("Camera", selection: $webcamService.selectedCameraID) {
                        ForEach(webcamService.cameras) { camera in
                            Text(camera.name).tag(Optional(camera.id))
                        }
                    }
                    .frame(maxWidth: 300)
                }
            }
            .padding()

            Divider()

            Group {
                switch webcamService.permission {
                case .denied, .restricted:
                    ContentUnavailableView {
                        Label("Camera access is off", systemImage: "camera.fill")
                    } description: {
                        Text("Allow TwainBridge to use the camera in Privacy & Security, then reopen webcam capture.")
                    } actions: {
                        Button("Open Privacy & Security") { openCameraPrivacySettings() }
                    }
                case .authorized where webcamService.cameras.isEmpty:
                    ContentUnavailableView(
                        "No webcam available",
                        systemImage: "video.slash",
                        description: Text("Connect a camera or enable Continuity Camera, then refresh.")
                    )
                default:
                    WebcamPreview(session: webcamService.session)
                        .background(Color.black)
                        .overlay(alignment: .center) {
                            if webcamService.activity.isBusy {
                                ProgressView(webcamService.activity.label)
                                    .padding(14)
                                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
                            }
                        }
                }
            }
            .frame(minHeight: 440)

            Divider()

            HStack {
                Label(webcamService.activity.label, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Spacer()
                Button("Refresh Cameras") {
                    Task { await webcamService.prepareSession() }
                }
                Button("Cancel") { dismissWindow(id: "webcam") }
                Button {
                    webcamService.capturePhoto()
                } label: {
                    Label("Capture Photo", systemImage: "camera.shutter.button")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCapture)
                .accessibilityIdentifier("webcam.capture")
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 580)
        .task { await webcamService.prepareSession() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase != .active, newPhase == .active else { return }
            Task { await webcamService.prepareSession() }
        }
        .onDisappear { webcamService.stopSession() }
        .onChange(of: webcamService.captureSequence) { _, _ in
            dismissWindow(id: "webcam")
        }
    }

    private var canCapture: Bool {
        webcamService.activity == .ready
            && !scannerService.activity.isBusy
            && draftStore.actionableCount < 20
            && !webcamService.hasUnsecuredCapturedPhoto
    }

    private var statusSymbol: String {
        switch webcamService.activity {
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .capturing: "camera.fill"
        default: "video.fill"
        }
    }

    private var statusColor: Color {
        if case .failed = webcamService.activity { return .orange }
        return .secondary
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct WebcamPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> WebcamPreviewView {
        WebcamPreviewView(session: session)
    }

    func updateNSView(_ nsView: WebcamPreviewView, context: Context) {
        nsView.previewLayer.session = session
    }
}

private final class WebcamPreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
