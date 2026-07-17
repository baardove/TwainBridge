@preconcurrency import Carbon
import Foundation

private let scanHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard result == noErr,
          hotKeyID.signature == ScanHotKeyService.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let address = UInt(bitPattern: userData)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let service = Unmanaged<ScanHotKeyService>.fromOpaque(pointer).takeUnretainedValue()
        service.handleRegisteredShortcut(id: hotKeyID.id)
    }
    return noErr
}

@MainActor
final class ScanHotKeyService: ObservableObject {
    nonisolated static let signature: OSType = 0x54574252 // TWBR
    nonisolated static let scanRegistrationID: UInt32 = 1
    nonisolated static let webcamRegistrationID: UInt32 = 2

    @Published var scanConfiguration: ScanHotKeyConfiguration {
        didSet {
            persist(scanConfiguration, key: scanDefaultsKey)
            updateRegistrations()
        }
    }
    @Published var webcamConfiguration: ScanHotKeyConfiguration {
        didSet {
            persist(webcamConfiguration, key: webcamDefaultsKey)
            updateRegistrations()
        }
    }
    @Published private(set) var scanRegistrationError: String?
    @Published private(set) var webcamRegistrationError: String?
    @Published private(set) var isScanRegistered = false
    @Published private(set) var isWebcamRegistered = false

    var onScanTrigger: (() -> Void)?
    var onWebcamTrigger: (() -> Void)?

    private let defaults: UserDefaults
    private let registersWithSystem: Bool
    private let scanDefaultsKey = "scanner.globalHotKey"
    private let webcamDefaultsKey = "webcam.globalHotKey"
    private var scanHotKeyReference: EventHotKeyRef?
    private var webcamHotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var eventHandlerInstalled = false

    init(defaults: UserDefaults = .standard, registersWithSystem: Bool = true) {
        self.defaults = defaults
        self.registersWithSystem = registersWithSystem
        if let data = defaults.data(forKey: scanDefaultsKey),
           let stored = try? JSONDecoder().decode(ScanHotKeyConfiguration.self, from: data) {
            scanConfiguration = stored.sanitized()
        } else {
            scanConfiguration = .defaultValue
        }
        if let data = defaults.data(forKey: webcamDefaultsKey),
           let stored = try? JSONDecoder().decode(ScanHotKeyConfiguration.self, from: data) {
            webcamConfiguration = stored.sanitized(fallback: .webcamDefaultValue)
        } else {
            webcamConfiguration = .webcamDefaultValue
        }
        if registersWithSystem { installEventHandler() }
        updateRegistrations()
    }

    func resetScan() {
        scanConfiguration = .defaultValue
    }

    func resetWebcam() {
        webcamConfiguration = .webcamDefaultValue
    }

    func handleRegisteredShortcut(id: UInt32) {
        switch id {
        case Self.scanRegistrationID where scanConfiguration.enabled && isScanRegistered:
            onScanTrigger?()
        case Self.webcamRegistrationID where webcamConfiguration.enabled && isWebcamRegistered:
            onWebcamTrigger?()
        default:
            break
        }
    }

    func stop() {
        unregisterHotKeys()
        if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
        eventHandlerReference = nil
        eventHandlerInstalled = false
        isScanRegistered = false
        isWebcamRegistered = false
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            scanHotKeyEventHandler,
            1,
            &eventType,
            pointer,
            &eventHandlerReference
        )
        if result != noErr {
            let message = String(localized: "The global shortcut service could not start. Restart TwainBridge and try again.")
            scanRegistrationError = message
            webcamRegistrationError = message
        } else {
            eventHandlerInstalled = true
        }
    }

    private func updateRegistrations() {
        unregisterHotKeys()
        scanRegistrationError = nil
        webcamRegistrationError = nil
        isScanRegistered = false
        isWebcamRegistered = false

        register(
            configuration: scanConfiguration,
            id: Self.scanRegistrationID,
            label: String(localized: "scan"),
            reference: &scanHotKeyReference,
            isRegistered: &isScanRegistered,
            error: &scanRegistrationError
        )
        register(
            configuration: webcamConfiguration,
            id: Self.webcamRegistrationID,
            label: String(localized: "webcam"),
            reference: &webcamHotKeyReference,
            isRegistered: &isWebcamRegistered,
            error: &webcamRegistrationError
        )
    }

    private func register(
        configuration: ScanHotKeyConfiguration,
        id: UInt32,
        label: String,
        reference: inout EventHotKeyRef?,
        isRegistered: inout Bool,
        error: inout String?
    ) {
        guard configuration.enabled else { return }
        guard configuration.hasPrimaryModifier else {
            error = String(localized: "Add Command, Option, or Control to the \(label) shortcut.")
            return
        }
        guard ScanHotKeyKey.contains(configuration.keyCode) else {
            error = String(localized: "Choose a supported key for the \(label) shortcut.")
            return
        }
        guard registersWithSystem else { return }
        guard eventHandlerInstalled else {
            error = String(localized: "The global shortcut service could not start. Restart TwainBridge and try again.")
            return
        }

        var registeredReference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: id)
        let result = RegisterEventHotKey(
            configuration.keyCode,
            carbonModifiers(for: configuration),
            identifier,
            GetApplicationEventTarget(),
            0,
            &registeredReference
        )
        guard result == noErr, let registeredReference else {
            error = result == OSStatus(eventHotKeyExistsErr)
                ? String(localized: "That shortcut is already used. Choose a different combination.")
                : String(localized: "The \(label) shortcut could not be registered. Choose a different combination or restart TwainBridge.")
            return
        }
        reference = registeredReference
        isRegistered = true
    }

    private func unregisterHotKeys() {
        if let scanHotKeyReference { UnregisterEventHotKey(scanHotKeyReference) }
        if let webcamHotKeyReference { UnregisterEventHotKey(webcamHotKeyReference) }
        scanHotKeyReference = nil
        webcamHotKeyReference = nil
    }

    private func carbonModifiers(for configuration: ScanHotKeyConfiguration) -> UInt32 {
        var modifiers: UInt32 = 0
        if configuration.command { modifiers |= UInt32(cmdKey) }
        if configuration.option { modifiers |= UInt32(optionKey) }
        if configuration.control { modifiers |= UInt32(controlKey) }
        if configuration.shift { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private func persist(_ configuration: ScanHotKeyConfiguration, key: String) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }
}
