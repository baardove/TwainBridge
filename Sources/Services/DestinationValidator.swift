import Foundation
import Network

enum DestinationValidator {
    private static let reservedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "content-type"
    ]

    static func validate(_ profile: DestinationProfile, hasAuthenticationSecret: Bool) -> [DestinationValidationIssue] {
        var issues: [DestinationValidationIssue] = []
        func add(_ id: String, _ message: String, severity: DestinationValidationSeverity = .error) {
            issues.append(.init(id: id, severity: severity, message: message))
        }
        func addVerbatim(_ id: String, _ message: String) {
            issues.append(.init(id: id, severity: .error, message: message))
        }

        guard let components = URLComponents(string: profile.endpointURL),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false else {
            add("url.invalid", String(localized: "Enter a complete destination URL."))
            return issues
        }
        if !isAllowedTransport(scheme: scheme, host: components.host) {
            add("url.https", String(localized: "The destination must use HTTPS, except for local-network endpoints."))
        }
        if components.user != nil || components.password != nil {
            add("url.credentials", String(localized: "Credentials cannot be embedded in the destination URL."))
        }
        if components.query != nil {
            add("url.query", String(localized: "Configure URL query values as named Query parameters so they can be validated and sanitized."))
        }
        if components.fragment != nil {
            add("url.fragment", String(localized: "The destination URL cannot contain a fragment."))
        }
        if containsControlCharacters(profile.endpointURL) {
            add("url.control", String(localized: "The destination URL contains invalid control characters."))
        }
        if let issue = DestinationURLTemplate.validationIssue(for: profile) {
            addVerbatim("url.placeholder", issue)
        }
        if profile.method != .post {
            add("method.mvp", String(localized: "Only POST is enabled in this release."))
        }
        if !validFieldName(profile.fileFieldName) {
            add("file-field.invalid", String(localized: "Enter a valid multipart file field name."))
        }
        if profile.fileFieldConvention == .customPerDocument,
           let issue = MultipartFileFieldName.validationIssue(for: profile) {
            addVerbatim("file-field.pattern", issue)
        }
        if profile.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("filename-pattern.empty", String(localized: "Enter a filename pattern."))
        }
        let placeholders = profile.filenamePattern.matches(of: /\{[^}]+\}/).map { String($0.output) }
        let allowedPlaceholders: Set<String> = ["{document_id}", "{batch_id}", "{index}", "{name}", "{date}"]
        if placeholders.contains(where: { !allowedPlaceholders.contains($0) }) {
            add("filename-pattern.placeholder", String(localized: "The filename pattern contains an unsupported placeholder."))
        }
        if profile.includeBatchManifest && !validFieldName(profile.manifestFieldName) {
            add("manifest-field.invalid", String(localized: "Enter a valid manifest field name."))
        }
        if profile.maximumDocumentsPerBatch < 1 || profile.maximumDocumentsPerBatch > 20 {
            add("batch.count", String(localized: "Maximum documents must be between 1 and 20."))
        }
        if let maximum = profile.maximumPagesPerDocument, maximum < 1 {
            add("pages.count", String(localized: "Maximum pages must be positive."))
        }
        if profile.requestTimeout < 1 || profile.requestTimeout > 600 {
            add("timeout.range", String(localized: "Request timeout must be between 1 and 600 seconds."))
        }
        if profile.acceptedOutputFormats.isEmpty {
            add("format.empty", String(localized: "Select at least one accepted output format."))
        }
        if let maximum = profile.maximumFileBytes, maximum <= 0 {
            add("file-size.range", String(localized: "Maximum file size must be positive."))
        }
        if let maximum = profile.maximumBatchBytes, maximum <= 0 {
            add("batch-size.range", String(localized: "Maximum batch size must be positive."))
        }
        if !validHeaderName(profile.idempotencyHeaderName) {
            add("idempotency.header", String(localized: "The idempotency header name is invalid."))
        }
        for host in profile.allowedRedirectHosts {
            if !validHost(host) {
                add("redirect-host.\(host)", String(localized: "Redirect allowlist entries must be hostnames without a scheme, path, port, or credentials."))
            }
        }

        if profile.authentication.kind != .none {
            if !hasAuthenticationSecret {
                add("auth.secret", String(localized: "Enter the destination credential and store it in Keychain."))
            }
            if !validHeaderName(profile.authentication.headerName) {
                add("auth.header", String(localized: "The authentication header name is invalid."))
            }
            if reservedHeaders.contains(profile.authentication.headerName.lowercased()) {
                add("auth.reserved", String(localized: "That authentication header is reserved by HTTP."))
            }
        }

        var namesByLocation: [ParameterLocation: Set<String>] = [:]
        let reservedFormFields: Set<String> = [
            "batch_id", "request_id", "document_id", "page_count", "document_index"
        ]
        let possibleFileFields = Set((0..<max(profile.maximumDocumentsPerBatch, 1)).map { index in
            MultipartFileFieldName.resolve(profile: profile, index: index, documentID: UUID()).lowercased()
        })
        for parameter in profile.parameters where parameter.enabled {
            let normalizedName = parameter.name.lowercased()
            if parameter.name.isEmpty || containsControlCharacters(parameter.name) {
                add("parameter.\(parameter.id).name", String(localized: "A parameter has an invalid or empty name."))
            }
            if parameter.location == .header {
                if !validHeaderName(parameter.name) {
                    add("parameter.\(parameter.id).header", String(localized: "Header ‘\(parameter.name)’ has an invalid name."))
                }
                if reservedHeaders.contains(normalizedName) {
                    add("parameter.\(parameter.id).reserved", String(localized: "Header ‘\(parameter.name)’ is reserved by HTTP."))
                }
                if normalizedName == profile.idempotencyHeaderName.lowercased() {
                    add("parameter.\(parameter.id).idempotency", String(localized: "Header ‘\(parameter.name)’ is managed by TwainBridge for idempotency."))
                }
                if profile.authentication.kind != .none,
                   normalizedName == profile.authentication.headerName.lowercased() {
                    add("parameter.\(parameter.id).authentication", String(localized: "Header ‘\(parameter.name)’ is already used by Authentication."))
                }
                if normalizedName == "authorization" {
                    add("parameter.\(parameter.id).authorization", String(localized: "Authorization must be configured in Authentication."))
                }
            } else if !validFieldName(parameter.name) {
                add("parameter.\(parameter.id).field", String(localized: "Parameter ‘\(parameter.name)’ has an invalid name."))
            }
            if parameter.location == .form {
                let isManifestField = profile.includeBatchManifest
                    && normalizedName == profile.manifestFieldName.lowercased()
                if reservedFormFields.contains(normalizedName)
                    || possibleFileFields.contains(normalizedName)
                    || isManifestField {
                    add("parameter.\(parameter.id).transport-field", String(localized: "Form field ‘\(parameter.name)’ is reserved by the multipart document mapping."))
                }
            }
            if namesByLocation[parameter.location, default: []].contains(normalizedName) {
                add("parameter.\(parameter.id).duplicate", String(localized: "Parameter ‘\(parameter.name)’ is duplicated in \(parameter.location.rawValue)."))
            }
            namesByLocation[parameter.location, default: []].insert(normalizedName)
            if parameter.location == .query && parameter.sensitive {
                add("parameter.\(parameter.id).query-secret", String(localized: "Sensitive values cannot be placed in the URL query."))
            }
            if profile.batchPolicy == .multipleDocuments,
               profile.batchRequestMode == .oneMultipartRequest,
               parameter.scope == .document,
               parameter.location != .form {
                add(
                    "parameter.\(parameter.id).document-location",
                    String(localized: "Document-scoped values in a one-request batch must use the form location so they can be placed in the manifest.")
                )
            }
            if parameter.sensitive && parameter.value != nil {
                add("parameter.\(parameter.id).plaintext", String(localized: "Sensitive parameter values must be stored in Keychain."))
            }
            if let value = parameter.value, containsControlCharacters(value), parameter.location == .header {
                add("parameter.\(parameter.id).control", String(localized: "Header ‘\(parameter.name)’ contains a line break or control character."))
            }
            if parameter.valueSource == .builtIn && parameter.builtInValue == nil {
                add("parameter.\(parameter.id).builtin", String(localized: "Choose a built-in value for ‘\(parameter.name)’."))
            }
            if let issue = DestinationParameterValidator.configurationIssue(for: parameter) {
                addVerbatim("parameter.\(parameter.id).validation", issue)
            }
        }

        if profile.response.maximumBodyBytes < 0 || profile.response.maximumBodyBytes > 10_485_760 {
            add("response.size", String(localized: "Maximum response size must be between 0 and 10 MB."))
        }
        if profile.response.successStatuses.lowerBound < 100
            || profile.response.successStatuses.upperBound > 599
            || profile.response.successStatuses.lowerBound > profile.response.successStatuses.upperBound {
            add("response.status", String(localized: "The success status-code range is invalid."))
        }
        if profile.response.mode == .customJSON && profile.response.custom.successPath.isEmpty {
            add("response.success-path", String(localized: "Custom JSON requires a success path."))
        }

        if !profile.receiverSupportsIdempotency {
            add(
                "idempotency.warning",
                String(localized: "Automatic retry is disabled because the receiver does not guarantee idempotency."),
                severity: .warning
            )
        }
        return issues
    }

    static func validHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func validFieldName(_ value: String) -> Bool {
        !value.isEmpty && !containsControlCharacters(value) && !value.contains("\"")
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func isAllowedTransportURL(_ url: URL) -> Bool {
        isAllowedTransport(scheme: url.scheme, host: url.host)
    }

    static func isAllowedTransport(scheme: String?, host: String?) -> Bool {
        guard let scheme = scheme?.lowercased(), let host else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLocalNetworkHost(host)
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".local")
            || normalized.hasSuffix(".lan")
            || normalized.hasSuffix(".home.arpa")
            || !normalized.contains(".") && !normalized.contains(":") {
            return true
        }
        if let address = IPv4Address(normalized) {
            let octets = [UInt8](address.rawValue)
            guard octets.count == 4 else { return false }
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        if let address = IPv6Address(normalized) {
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = bytes[0] & 0xfe == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }
        return false
    }

    static func validHost(_ value: String) -> Bool {
        guard !value.isEmpty,
              !containsControlCharacters(value),
              !value.contains(":"),
              !value.contains("/"),
              !value.contains("@"),
              let components = URLComponents(string: "https://\(value)"),
              components.host?.lowercased() == value.lowercased() else { return false }
        return true
    }
}
