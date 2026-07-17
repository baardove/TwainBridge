import XCTest
@testable import TwainBridge

@MainActor
final class HotKeyTests: XCTestCase {
    func testConfigurationFormatsAndValidatesShortcut() {
        var configuration = ScanHotKeyConfiguration.defaultValue
        XCTAssertEqual(configuration.displayName, "⌥⌘S")
        XCTAssertTrue(configuration.hasPrimaryModifier)

        configuration.command = false
        configuration.option = false
        configuration.shift = true
        XCTAssertFalse(configuration.hasPrimaryModifier)

        configuration.control = true
        configuration.keyCode = 122
        XCTAssertTrue(configuration.hasPrimaryModifier)
        XCTAssertEqual(configuration.displayName, "⌃⇧F1")

        configuration.keyCode = UInt32.max
        XCTAssertEqual(configuration.sanitized(), .defaultValue)
    }

    func testServicePersistsConfigurationAndRejectsModifierlessShortcut() throws {
        let suiteName = "TwainBridge.HotKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = ScanHotKeyService(defaults: defaults, registersWithSystem: false)
        service.scanConfiguration.enabled = true
        service.scanConfiguration.command = false
        service.scanConfiguration.option = false
        service.scanConfiguration.control = false
        service.scanConfiguration.shift = true
        XCTAssertNotNil(service.scanRegistrationError)

        service.scanConfiguration.control = true
        service.scanConfiguration.keyCode = 111
        XCTAssertNil(service.scanRegistrationError)
        XCTAssertEqual(service.scanConfiguration.displayName, "⌃⇧F12")

        service.webcamConfiguration.enabled = true
        service.webcamConfiguration.keyCode = 8
        XCTAssertNil(service.webcamRegistrationError)
        XCTAssertEqual(service.webcamConfiguration.displayName, "⌥⌘C")

        let restored = ScanHotKeyService(defaults: defaults, registersWithSystem: false)
        XCTAssertEqual(restored.scanConfiguration, service.scanConfiguration)
        XCTAssertEqual(restored.webcamConfiguration, service.webcamConfiguration)
    }

    func testWebcamConfigurationUsesIndependentFallbackAndDefault() throws {
        XCTAssertEqual(ScanHotKeyConfiguration.webcamDefaultValue.displayName, "⌥⌘C")

        var invalid = ScanHotKeyConfiguration.webcamDefaultValue
        invalid.keyCode = UInt32.max
        XCTAssertEqual(
            invalid.sanitized(fallback: .webcamDefaultValue),
            .webcamDefaultValue
        )
    }
}
