import Foundation

enum DestinationURLTemplate {
    private static let builtIns: Set<String> = ["batch_id", "document_id", "request_id"]

    static func validationIssue(for profile: DestinationProfile) -> String? {
        let expression = /\{([A-Za-z][A-Za-z0-9_]*)\}/
        let matches = profile.endpointURL.matches(of: expression)
        let matchedBraces = matches.count * 2
        let actualBraces = profile.endpointURL.filter { $0 == "{" || $0 == "}" }.count
        if matchedBraces != actualBraces {
            return String(localized: "The destination URL contains an invalid placeholder.")
        }
        guard !matches.isEmpty else { return nil }

        guard let schemeEnd = profile.endpointURL.range(of: "://")?.upperBound else {
            return String(localized: "The destination URL is invalid.")
        }
        guard let pathStart = profile.endpointURL[schemeEnd...].firstIndex(of: "/") else {
            return String(localized: "URL placeholders are supported only in the path.")
        }
        let pathEnd = profile.endpointURL[pathStart...]
            .firstIndex(where: { $0 == "?" || $0 == "#" }) ?? profile.endpointURL.endIndex

        let parameters = profile.parameters.filter(\.enabled).reduce(into: [String: DestinationParameter]()) {
            $0[$1.name] = $1
        }
        for match in matches {
            let name = String(match.output.1)
            if match.range.lowerBound < pathStart || match.range.upperBound > pathEnd {
                return String(localized: "URL placeholders are supported only in the path.")
            }
            if builtIns.contains(name) {
                if name == "document_id",
                   profile.batchPolicy == .multipleDocuments,
                   profile.batchRequestMode == .oneMultipartRequest {
                    return String(localized: "A document_id URL placeholder is ambiguous for a one-request multi-document batch.")
                }
                continue
            }
            guard let parameter = parameters[name] else {
                return String(localized: "The URL placeholder ‘\(name)’ does not match an enabled parameter.")
            }
            if parameter.sensitive {
                return String(localized: "Sensitive values cannot be placed in the destination URL.")
            }
            if parameter.scope == .document,
               profile.batchPolicy == .multipleDocuments,
               profile.batchRequestMode == .oneMultipartRequest {
                return String(localized: "A document-scoped URL placeholder is ambiguous for a one-request multi-document batch.")
            }
        }
        return nil
    }

    static func resolve(
        _ template: String,
        batchID: UUID,
        documentID: UUID?,
        requestID: UUID,
        parameterValues: [String: String]
    ) throws -> String {
        let expression = /\{([A-Za-z][A-Za-z0-9_]*)\}/
        var resolved = template
        for match in template.matches(of: expression).reversed() {
            let name = String(match.output.1)
            let value: String? = switch name {
            case "batch_id": batchID.uuidString
            case "document_id": documentID?.uuidString
            case "request_id": requestID.uuidString
            default: parameterValues[name]
            }
            guard let value, let encoded = encodePathComponent(value) else {
                throw UploadEngineError.destinationConstraint(
                    String(localized: "The URL placeholder ‘\(name)’ has no value.")
                )
            }
            resolved.replaceSubrange(match.range, with: encoded)
        }
        return resolved
    }

    private static func encodePathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
