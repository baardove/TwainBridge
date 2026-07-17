@preconcurrency import AVFoundation
import Combine
import Foundation

struct WebcamSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum WebcamPermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        self = switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

enum WebcamCaptureActivity: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case ready
    case capturing
    case completed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .requestingPermission, .preparing, .capturing: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .idle: String(localized: "Webcam idle")
        case .requestingPermission: String(localized: "Requesting camera access…")
        case .preparing: String(localized: "Preparing webcam…")
        case .ready: String(localized: "Ready to capture")
        case .capturing: String(localized: "Capturing photo…")
        case .completed: String(localized: "Photo captured")
        case let .failed(message): message
        }
    }
}

private struct WebcamPhotoError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private final class WebcamPhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @MainActor @Sendable (Result<Data, WebcamPhotoError>) -> Void

    init(completion: @escaping @MainActor @Sendable (Result<Data, WebcamPhotoError>) -> Void) {
        self.completion = completion
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let result: Result<Data, WebcamPhotoError>
        if let error {
            result = .failure(.init(message: error.localizedDescription))
        } else if let data = photo.fileDataRepresentation(), !data.isEmpty {
            result = .success(data)
        } else {
            result = .failure(.init(message: String(localized: "The webcam returned an empty photo.")))
        }
        Task { @MainActor [completion] in completion(result) }
    }
}

@MainActor
final class WebcamCaptureService: ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var cameras: [WebcamSnapshot] = []
    @Published var selectedCameraID: String? {
        didSet {
            if let selectedCameraID {
                defaults.set(selectedCameraID, forKey: selectedCameraDefaultsKey)
            } else {
                defaults.removeObject(forKey: selectedCameraDefaultsKey)
            }
            if wantsSession { configureAndStartSession() }
        }
    }
    @Published private(set) var permission: WebcamPermissionState
    @Published private(set) var activity: WebcamCaptureActivity = .idle
    @Published private(set) var completedCaptureResult: CompletedScanResult?
    @Published private(set) var captureSequence = UUID()

    private let defaults: UserDefaults
    private let selectedCameraDefaultsKey = "webcam.defaultCameraID"
    private let photoOutput = AVCapturePhotoOutput()
    private var devicesByID: [String: AVCaptureDevice] = [:]
    private var photoProcessor: WebcamPhotoProcessor?
    private var stagingDirectory: URL?
    private var wantsSession = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedCameraID = defaults.string(forKey: selectedCameraDefaultsKey)
        permission = WebcamPermissionState(AVCaptureDevice.authorizationStatus(for: .video))
        refreshCameras()
    }

    var selectedCamera: WebcamSnapshot? {
        guard let selectedCameraID else { return cameras.first }
        return cameras.first { $0.id == selectedCameraID }
    }

    var isSessionRunning: Bool { session.isRunning }
    var hasUnsecuredCapturedPhoto: Bool { completedCaptureResult != nil }

    func prepareSession() async {
        wantsSession = true
        permission = WebcamPermissionState(AVCaptureDevice.authorizationStatus(for: .video))
        if permission == .notDetermined {
            activity = .requestingPermission
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .authorized : .denied
        }
        guard permission == .authorized else {
            if session.isRunning { session.stopRunning() }
            activity = .failed(String(localized: "Camera access is required to use webcam capture."))
            return
        }
        // Camera permission can change while System Settings is in front. Keep
        // automatic reconfiguration suspended while discovery normalizes the
        // persisted selection, then configure exactly once with fresh devices.
        wantsSession = false
        refreshCameras()
        wantsSession = true
        configureAndStartSession()
    }

    func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        devicesByID = Dictionary(uniqueKeysWithValues: discovery.devices.map { ($0.uniqueID, $0) })
        cameras = discovery.devices
            .map { WebcamSnapshot(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let selectedCameraID, devicesByID[selectedCameraID] == nil {
            self.selectedCameraID = nil
        }
        if selectedCameraID == nil {
            selectedCameraID = cameras.first?.id
        }
    }

    func stopSession() {
        wantsSession = false
        if session.isRunning { session.stopRunning() }
        if completedCaptureResult == nil { activity = .idle }
    }

    func capturePhoto() {
        guard completedCaptureResult == nil else {
            activity = .failed(String(localized: "Secure or discard the previous webcam photo before taking another one."))
            return
        }
        guard permission == .authorized, session.isRunning else {
            activity = .failed(String(localized: "The webcam is not ready."))
            return
        }
        guard photoOutput.availablePhotoCodecTypes.contains(.jpeg) else {
            activity = .failed(String(localized: "This webcam does not provide JPEG photo capture."))
            return
        }
        activity = .capturing
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        let processor = WebcamPhotoProcessor { [weak self] result in
            guard let self else { return }
            self.photoProcessor = nil
            switch result {
            case let .success(data): self.stageCapturedPhoto(data)
            case let .failure(error): self.activity = .failed(error.localizedDescription)
            }
        }
        photoProcessor = processor
        photoOutput.capturePhoto(with: settings, delegate: processor)
    }

    func acknowledgeCompletedCapture() {
        removeStagingDirectory()
        completedCaptureResult = nil
        activity = session.isRunning ? .ready : .idle
    }

    func retrySecuringCapturedPhoto() {
        guard let result = completedCaptureResult else { return }
        completedCaptureResult = nil
        completedCaptureResult = result
    }

    func discardPendingCapture() {
        removeStagingDirectory()
        completedCaptureResult = nil
        activity = session.isRunning ? .ready : .idle
    }

    func reportDraftImportFailure(_ error: Error) {
        activity = .failed(
            String(localized: "The photo was captured but could not be secured locally. \(error.localizedDescription)")
        )
    }

    func prepareForTermination() {
        stopSession()
    }

    private func configureAndStartSession() {
        guard wantsSession, permission == .authorized else { return }
        guard let cameraID = selectedCameraID ?? cameras.first?.id,
              let device = devicesByID[cameraID] else {
            activity = .failed(String(localized: "No webcam is available."))
            return
        }

        activity = .preparing
        session.beginConfiguration()
        session.sessionPreset = .photo
        for input in session.inputs { session.removeInput(input) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw WebcamPhotoError(message: String(localized: "The selected webcam cannot be added to the capture session."))
            }
            session.addInput(input)
            if !session.outputs.contains(photoOutput) {
                guard session.canAddOutput(photoOutput) else {
                    throw WebcamPhotoError(message: String(localized: "Photo capture is unavailable for the selected webcam."))
                }
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            activity = .ready
        } catch {
            session.commitConfiguration()
            activity = .failed(error.localizedDescription)
        }
    }

    private func stageCapturedPhoto(_ data: Data) {
        guard let cameraID = selectedCameraID,
              let camera = devicesByID[cameraID] else {
            activity = .failed(String(localized: "The selected webcam disconnected before the photo could be secured."))
            return
        }
        let request = ScanRequest(
            scannerID: "webcam:\(cameraID)",
            source: .automatic,
            colorMode: .color,
            resolution: 300,
            duplex: false,
            pageSize: .automatic,
            orientation: .automatic
        )
        do {
            try DiskCapacityGuard.verify(
                at: ScanStagingRecovery.defaultRootURL.deletingLastPathComponent(),
                requiredBytes: Int64(data.count)
            )
            let directory = try ScanStagingRecovery.createDirectory(
                request: request,
                scannerName: String(localized: "Webcam — \(camera.localizedName)")
            )
            let photoURL = directory.appendingPathComponent("webcam-capture.jpg")
            try data.write(to: photoURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: photoURL.path)
            stagingDirectory = directory
            completedCaptureResult = CompletedScanResult(
                id: UUID(),
                pageURLs: [photoURL],
                request: request,
                scannerName: String(localized: "Webcam — \(camera.localizedName)"),
                completedAt: Date(),
                interrupted: false
            )
            captureSequence = UUID()
            activity = .completed
        } catch {
            activity = .failed(
                String(localized: "The webcam photo could not be staged securely. \(error.localizedDescription)")
            )
        }
    }

    private func removeStagingDirectory() {
        guard let stagingDirectory else { return }
        try? FileManager.default.removeItem(at: stagingDirectory)
        self.stagingDirectory = nil
    }
}
