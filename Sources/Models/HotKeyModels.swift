import Foundation

struct ScanHotKeyKey: Identifiable, Equatable, Sendable {
    var id: UInt32 { keyCode }
    var keyCode: UInt32
    var label: String

    static let options: [ScanHotKeyKey] = [
        .init(keyCode: 0, label: "A"), .init(keyCode: 11, label: "B"),
        .init(keyCode: 8, label: "C"), .init(keyCode: 2, label: "D"),
        .init(keyCode: 14, label: "E"), .init(keyCode: 3, label: "F"),
        .init(keyCode: 5, label: "G"), .init(keyCode: 4, label: "H"),
        .init(keyCode: 34, label: "I"), .init(keyCode: 38, label: "J"),
        .init(keyCode: 40, label: "K"), .init(keyCode: 37, label: "L"),
        .init(keyCode: 46, label: "M"), .init(keyCode: 45, label: "N"),
        .init(keyCode: 31, label: "O"), .init(keyCode: 35, label: "P"),
        .init(keyCode: 12, label: "Q"), .init(keyCode: 15, label: "R"),
        .init(keyCode: 1, label: "S"), .init(keyCode: 17, label: "T"),
        .init(keyCode: 32, label: "U"), .init(keyCode: 9, label: "V"),
        .init(keyCode: 13, label: "W"), .init(keyCode: 7, label: "X"),
        .init(keyCode: 16, label: "Y"), .init(keyCode: 6, label: "Z"),
        .init(keyCode: 29, label: "0"), .init(keyCode: 18, label: "1"),
        .init(keyCode: 19, label: "2"), .init(keyCode: 20, label: "3"),
        .init(keyCode: 21, label: "4"), .init(keyCode: 23, label: "5"),
        .init(keyCode: 22, label: "6"), .init(keyCode: 26, label: "7"),
        .init(keyCode: 28, label: "8"), .init(keyCode: 25, label: "9"),
        .init(keyCode: 122, label: "F1"), .init(keyCode: 120, label: "F2"),
        .init(keyCode: 99, label: "F3"), .init(keyCode: 118, label: "F4"),
        .init(keyCode: 96, label: "F5"), .init(keyCode: 97, label: "F6"),
        .init(keyCode: 98, label: "F7"), .init(keyCode: 100, label: "F8"),
        .init(keyCode: 101, label: "F9"), .init(keyCode: 109, label: "F10"),
        .init(keyCode: 103, label: "F11"), .init(keyCode: 111, label: "F12")
    ]

    static func label(for keyCode: UInt32) -> String {
        options.first(where: { $0.keyCode == keyCode })?.label ?? "?"
    }

    static func contains(_ keyCode: UInt32) -> Bool {
        options.contains(where: { $0.keyCode == keyCode })
    }
}

struct ScanHotKeyConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var keyCode: UInt32 = 1
    var command = true
    var option = true
    var control = false
    var shift = false

    static let defaultValue = ScanHotKeyConfiguration()
    static let webcamDefaultValue = ScanHotKeyConfiguration(
        enabled: false,
        keyCode: 8,
        command: true,
        option: true,
        control: false,
        shift: false
    )

    var hasPrimaryModifier: Bool { command || option || control }

    var displayName: String {
        var value = ""
        if control { value += "⌃" }
        if option { value += "⌥" }
        if shift { value += "⇧" }
        if command { value += "⌘" }
        return value + ScanHotKeyKey.label(for: keyCode)
    }

    func sanitized(fallback: ScanHotKeyConfiguration = .defaultValue) -> ScanHotKeyConfiguration {
        guard ScanHotKeyKey.contains(keyCode) else { return fallback }
        return self
    }
}
