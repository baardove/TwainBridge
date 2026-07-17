import Foundation

struct InterpretedResponse: Equatable, Sendable {
    enum Confirmation: Equatable, Sendable {
        case confirmed
        case applicationFailure
        case unconfirmed
    }

    var confirmation: Confirmation
    var message: String?
    var remoteID: String?
    var openURL: URL?
}

enum ResponseInterpreter {
    static func interpret(
        data: Data,
        statusCode: Int,
        contentType: String? = nil,
        validateContentType: Bool = false,
        configuration: ResponseConfiguration
    ) -> InterpretedResponse {
        guard configuration.successStatuses.contains(statusCode) else {
            return .init(
                confirmation: .applicationFailure,
                message: String(localized: "Server returned HTTP \(statusCode).")
            )
        }
        guard data.count <= configuration.maximumBodyBytes else {
            return .init(confirmation: .unconfirmed, message: String(localized: "The response exceeded the configured size limit."))
        }
        if configuration.mode == .statusOnly {
            return .init(confirmation: .confirmed, message: String(localized: "Connection accepted."))
        }
        if data.isEmpty {
            return configuration.permitsEmptyBody
                ? .init(confirmation: .confirmed, message: String(localized: "Connection accepted."))
                : .init(confirmation: .unconfirmed, message: String(localized: "The server returned an empty response."))
        }
        if validateContentType,
           configuration.mode != .statusOnly,
           !contentTypeMatches(actual: contentType, expected: configuration.expectedContentType) {
            return .init(
                confirmation: .unconfirmed,
                message: String(localized: "The response Content-Type did not match \(configuration.expectedContentType).")
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return .init(confirmation: .unconfirmed, message: String(localized: "The response was not valid JSON."))
        }
        let mapping = configuration.mode == .standardJSON
            ? CustomResponseMapping()
            : configuration.custom
        guard let success = value(at: mapping.successPath, in: object) as? Bool else {
            return .init(confirmation: .unconfirmed, message: String(localized: "The response did not contain a Boolean success value."))
        }
        if !configuration.missingOptionalFieldsAllowed {
            let requiredPaths = [mapping.messagePath, mapping.remoteIDPath, mapping.openURLPath]
                .filter { !$0.isEmpty }
            if let missing = requiredPaths.first(where: { value(at: $0, in: object) == nil }) {
                return .init(
                    confirmation: .unconfirmed,
                    message: String(localized: "The response did not contain the configured ‘\(missing)’ field.")
                )
            }
        }
        let message = sanitize(value(at: mapping.messagePath, in: object) as? String)
        if !success {
            return .init(confirmation: .applicationFailure, message: message ?? String(localized: "The receiver rejected the request."))
        }
        let remoteID = sanitize(value(at: mapping.remoteIDPath, in: object) as? String)
        let rawOpenURL = value(at: mapping.openURLPath, in: object) as? String
        let openURL = rawOpenURL.flatMap { value -> URL? in
            guard let url = URL(string: value),
                  DestinationValidator.isAllowedTransportURL(url),
                  url.host?.isEmpty == false else { return nil }
            return url
        }
        if rawOpenURL != nil, openURL == nil {
            return .init(confirmation: .unconfirmed, message: String(localized: "The response contained an invalid open URL."))
        }
        return .init(confirmation: .confirmed, message: message, remoteID: remoteID, openURL: openURL)
    }

    private static func contentTypeMatches(actual: String?, expected: String) -> Bool {
        let expected = expected.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !expected.isEmpty else { return true }
        guard let actual = actual?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        if expected == "*/*" { return true }
        if expected.hasSuffix("/*") {
            return actual.hasPrefix(String(expected.dropLast()) )
        }
        return actual == expected
    }

    static func value(at path: String, in object: Any) -> Any? {
        guard !path.isEmpty else { return nil }
        var current: Any? = object
        for component in path.split(separator: ".").map(String.init) {
            if let dictionary = current as? [String: Any] {
                current = dictionary[component]
            } else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func sanitize(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines).prefixString(500)
    }
}

private extension String {
    func prefixString(_ length: Int) -> String { String(prefix(length)) }
}
