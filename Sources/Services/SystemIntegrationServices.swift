import Foundation
import Network
import ServiceManagement
import UserNotifications

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.45webs.TwainBridge.network")
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                if self.isOnline {
                    let pending = self.continuations
                    self.continuations.removeAll()
                    pending.forEach { $0.resume() }
                }
            }
        }
        monitor.start(queue: queue)
    }

    func waitUntilOnline() async {
        if isOnline { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}

@MainActor
final class NotificationService: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "notifications.enabled") }
    }
    @Published private(set) var authorizationGranted = false

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorizationGranted = settings.authorizationStatus == .authorized
        }
    }

    func requestAuthorization() async {
        do {
            authorizationGranted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if !authorizationGranted { isEnabled = false }
        } catch {
            authorizationGranted = false
            isEnabled = false
        }
    }

    func notify(title: String, body: String) {
        guard isEnabled, authorizationGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "TWAINBRIDGE_STATUS"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    init() { refresh() }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch { lastError = error.localizedDescription }
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct EpsonDriverStatus: Equatable, Sendable {
    var installed: Bool
    var version: String?
    var verified: Bool
}

enum DriverInspector {
    static let requiredEpsonVersion = "6.7.84.0"
    static let epsonSupportURL = URL(string: "https://www.epson.eu/en_EU/support/sc/epson-workforce-ds-1660w/s/s1492")!

    static func epsonDS1660WStatus() -> EpsonDriverStatus {
        let paths = [
            "/Library/Image Capture/Devices/EPSON ES022D.app",
            "/Library/Image Capture/Devices/EPSON Scanner.app"
        ]
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let bundle = Bundle(path: path) else {
            return .init(installed: false, version: nil, verified: false)
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return .init(
            installed: true,
            version: version,
            verified: version.map { $0.compare(requiredEpsonVersion, options: .numeric) != .orderedAscending } ?? false
        )
    }
}

@MainActor
final class OnboardingService: ObservableObject {
    @Published var currentStep: Int {
        didSet { UserDefaults.standard.set(currentStep, forKey: "onboarding.step") }
    }
    @Published private(set) var isComplete: Bool

    init() {
        currentStep = UserDefaults.standard.integer(forKey: "onboarding.step")
        isComplete = UserDefaults.standard.bool(forKey: "onboarding.complete")
    }

    func complete() {
        isComplete = true
        UserDefaults.standard.set(true, forKey: "onboarding.complete")
    }

    func restart() {
        currentStep = 0
        isComplete = false
        UserDefaults.standard.set(false, forKey: "onboarding.complete")
    }
}
