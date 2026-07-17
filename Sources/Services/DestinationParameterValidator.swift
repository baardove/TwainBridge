import Foundation

enum DestinationParameterValidator {
    static func validate(value: String?, for parameter: DestinationParameter) -> String? {
        let label = parameter.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? parameter.label!
            : parameter.name
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return parameter.required ? String(localized: "Enter \(label).") : nil
        }
        if parameter.location == .header,
           trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return String(localized: "\(label) cannot contain line breaks or control characters.")
        }
        if let maximumLength = parameter.maximumLength, trimmed.count > maximumLength {
            return String(localized: "\(label) must contain no more than \(maximumLength) characters.")
        }

        var numericValue: Double?
        switch parameter.dataType {
        case .text:
            break
        case .integer:
            guard let value = Int64(trimmed) else { return String(localized: "\(label) must be a whole number.") }
            numericValue = Double(value)
        case .decimal:
            guard let value = Double(trimmed), value.isFinite else { return String(localized: "\(label) must be a number.") }
            numericValue = value
        case .boolean:
            guard ["true", "false", "1", "0", "yes", "no"].contains(trimmed.lowercased()) else {
                return String(localized: "\(label) must be true or false.")
            }
        case .date:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard formatter.date(from: trimmed) != nil else {
                return String(localized: "\(label) must use YYYY-MM-DD format.")
            }
        case .dateTime:
            guard ISO8601DateFormatter().date(from: trimmed) != nil else {
                return String(localized: "\(label) must be an ISO 8601 date and time.")
            }
        case .choice:
            guard parameter.allowedValues.contains(trimmed) else {
                return String(localized: "Choose an allowed value for \(label).")
            }
        }

        if let numericValue, let minimum = parameter.minimum, numericValue < minimum {
            return String(localized: "\(label) must be at least \(minimum).")
        }
        if let numericValue, let maximum = parameter.maximum, numericValue > maximum {
            return String(localized: "\(label) must be no more than \(maximum).")
        }
        if let expression = parameter.validationExpression, !expression.isEmpty,
           let regex = try? NSRegularExpression(pattern: expression),
           regex.firstMatch(
               in: trimmed,
               range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
           ) == nil {
            return parameter.helpText?.isEmpty == false
                ? parameter.helpText
                : String(localized: "\(label) does not match the required format.")
        }
        return nil
    }

    static func configurationIssue(for parameter: DestinationParameter) -> String? {
        if let maximumLength = parameter.maximumLength, maximumLength < 1 {
            return String(localized: "Maximum length for ‘\(parameter.name)’ must be positive.")
        }
        if let minimum = parameter.minimum, let maximum = parameter.maximum, minimum > maximum {
            return String(localized: "The minimum for ‘\(parameter.name)’ cannot exceed its maximum.")
        }
        if parameter.dataType == .choice && parameter.allowedValues.isEmpty {
            return String(localized: "Add at least one allowed value for ‘\(parameter.name)’.")
        }
        if let expression = parameter.validationExpression, !expression.isEmpty,
           (try? NSRegularExpression(pattern: expression)) == nil {
            return String(localized: "The validation expression for ‘\(parameter.name)’ is invalid.")
        }
        if parameter.valueSource == .fixed && !parameter.sensitive,
           let issue = validate(value: parameter.value ?? parameter.defaultValue, for: parameter) {
            return issue
        }
        if parameter.valueSource == .userEntered,
           let defaultValue = parameter.defaultValue,
           let issue = validate(value: defaultValue, for: parameter) {
            return String(localized: "Default value: \(issue)")
        }
        return nil
    }
}
