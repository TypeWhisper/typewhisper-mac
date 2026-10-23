import Foundation

/// A property list value read from managed preferences, before validation.
indirect enum ManagedPolicyRawValue: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case string(String)
    case array([ManagedPolicyRawValue])
    case dictionary([String: ManagedPolicyRawValue])
    /// Reals, dates, data and anything else; always invalid.
    case unsupported(typeName: String)

    /// Converts a value returned by CFPreferences. Booleans and numbers share `NSNumber`, so the
    /// Core Foundation type decides: `<true/>` stays a Boolean and `<integer>1</integer>` an integer.
    init(propertyList value: Any) {
        let object = value as AnyObject
        if CFGetTypeID(object) == CFBooleanGetTypeID(), let number = value as? NSNumber {
            self = .boolean(number.boolValue)
        } else if let number = value as? NSNumber {
            if CFNumberIsFloatType(number) {
                self = .unsupported(typeName: "real")
            } else if let integer = Int(exactly: number.int64Value) {
                self = .integer(integer)
            } else {
                self = .unsupported(typeName: "integer")
            }
        } else if let string = value as? String {
            self = .string(string)
        } else if let array = value as? [Any] {
            self = .array(array.map(ManagedPolicyRawValue.init(propertyList:)))
        } else if let dictionary = value as? [String: Any] {
            self = .dictionary(dictionary.mapValues(ManagedPolicyRawValue.init(propertyList:)))
        } else if value is Data {
            self = .unsupported(typeName: "data")
        } else if value is Date {
            self = .unsupported(typeName: "date")
        } else {
            self = .unsupported(typeName: "unknown")
        }
    }
}

/// The raw content of one read of the managed preferences.
struct ManagedPolicyReading: Sendable, Equatable {
    /// False when the source could not be read; the values are then meaningless.
    var readable: Bool
    /// A safe technical description of a read failure.
    var error: String?
    /// Values forced by a configuration profile, by key, including the `Recommended` dictionary.
    var forcedValues: [String: ManagedPolicyRawValue]
    /// Supported keys, or `Recommended`, present in the domain without being forced.
    var unmanagedKeys: Set<String>

    init(
        readable: Bool = true,
        error: String? = nil,
        forcedValues: [String: ManagedPolicyRawValue] = [:],
        unmanagedKeys: Set<String> = []
    ) {
        self.readable = readable
        self.error = error
        self.forcedValues = forcedValues
        self.unmanagedKeys = unmanagedKeys
    }

    /// A successful read of a domain without managed values.
    static let absent = ManagedPolicyReading()

    static func unreadable(_ error: String) -> ManagedPolicyReading {
        ManagedPolicyReading(readable: false, error: error)
    }
}

/// Turns a raw read into a validated snapshot following the contract shared with Windows
/// (typewhisper-win#470) and the macOS encoding in #1313.
///
/// Invalid enforced values block their capability instead of relaxing it; invalid recommendations
/// are only reported. Issue messages name keys and rules but never carry rejected values.
enum ManagedPolicyValidator {
    /// The longest accepted text value after trimming.
    static let maximumTextLength = 1024
    /// The most entries a list may hold after deduplication.
    static let maximumListEntries = 256

    /// A payload whose type is the app's domain makes macOS copy keys of the profile itself into
    /// the managed preferences, such as `PayloadUUID` and `_manualProfile`. They are not settings.
    static func isProfileMetadataKey(_ key: String) -> Bool {
        key.hasPrefix("Payload") || key.hasPrefix("_")
    }

    static func validate(_ reading: ManagedPolicyReading, revision: Int, readAt: Date) -> ManagedPolicySnapshot {
        guard reading.readable else {
            return ManagedPolicySnapshot(
                revision: revision,
                status: .unreadable,
                readAt: readAt,
                enforcedValues: [:],
                recommendedValues: [:],
                invalidEnforcedKeys: [],
                issues: [ManagedPolicyIssue(
                    key: nil,
                    scope: nil,
                    message: "The managed preferences could not be read (\(reading.error ?? "unknown error"))."
                )]
            )
        }

        var issues: [ManagedPolicyIssue] = []
        var rootValues = reading.forcedValues.filter { !isProfileMetadataKey($0.key) }
        let rawRecommended = rootValues.removeValue(forKey: ManagedPolicyKeys.recommendedDictionary)

        var enforced: [String: ManagedPolicyValue] = [:]
        var invalidEnforced: Set<String> = []
        validateScope(rootValues, scope: .enforced, values: &enforced, invalid: &invalidEnforced, issues: &issues)

        var recommended: [String: ManagedPolicyValue] = [:]
        switch rawRecommended {
        case nil:
            break
        case .dictionary(let entries):
            var invalidRecommended: Set<String> = []
            validateScope(entries, scope: .recommended, values: &recommended, invalid: &invalidRecommended, issues: &issues)
        default:
            issues.append(ManagedPolicyIssue(
                key: ManagedPolicyKeys.recommendedDictionary,
                scope: .recommended,
                message: "\(ManagedPolicyKeys.recommendedDictionary) must be a dictionary; the recommendations are ignored."
            ))
        }

        for key in reading.unmanagedKeys.sorted()
        where ManagedPolicyKeys.definition(named: key)?.acceptsUnmanagedValue != true {
            issues.append(ManagedPolicyIssue(
                key: key,
                scope: nil,
                message: "\(key) is set outside a configuration profile and is ignored."
            ))
        }

        // 管理员可能在应用偏好域中强制设置目录以外的键；
        // those do not make the policy present.
        let containsPolicyKey = reading.forcedValues.keys.contains { key in
            key == ManagedPolicyKeys.recommendedDictionary || ManagedPolicyKeys.definition(named: key) != nil
        }
        return ManagedPolicySnapshot(
            revision: revision,
            status: containsPolicyKey ? .present : .absent,
            readAt: readAt,
            enforcedValues: enforced,
            recommendedValues: recommended,
            invalidEnforcedKeys: invalidEnforced,
            issues: issues
        )
    }

    private static func validateScope(
        _ section: [String: ManagedPolicyRawValue],
        scope: ManagedPolicyScope,
        values: inout [String: ManagedPolicyValue],
        invalid: inout Set<String>,
        issues: inout [ManagedPolicyIssue]
    ) {
        for definition in ManagedPolicyKeys.all {
            let name = definition.name
            guard let raw = section[name] else { continue }
            if scope == .recommended && !definition.allowsRecommendation {
                issues.append(ManagedPolicyIssue(
                    key: name,
                    scope: scope,
                    message: "\(name) can only be enforced, not recommended; it is ignored."
                ))
                continue
            }
            switch validate(raw, as: definition) {
            case .success(let value):
                values[name] = value
            case .failure(let problem):
                invalid.insert(name)
                issues.append(ManagedPolicyIssue(key: name, scope: scope, message: "\(name) \(problem.message)."))
            }
        }

        validatePairs(scope: scope, values: &values, invalid: &invalid, issues: &issues)

        for name in section.keys.sorted() where ManagedPolicyKeys.definition(named: name) == nil {
            let message = if let match = ManagedPolicyKeys.caseInsensitiveMatch(for: name) {
                "\(name) is not a dictum managed setting; keys are case-sensitive (did you mean \(match)?)."
            } else {
                "\(name) is not a dictum managed setting and is not applied as one."
            }
            issues.append(ManagedPolicyIssue(key: name, scope: scope, message: message))
        }
    }

    // Both members of a pair must be valid at the same scope; otherwise the pair is unusable there.
    private static func validatePairs(
        scope: ManagedPolicyScope,
        values: inout [String: ManagedPolicyValue],
        invalid: inout Set<String>,
        issues: inout [ManagedPolicyIssue]
    ) {
        for definition in ManagedPolicyKeys.all {
            guard let partner = definition.pairedWith, definition.name < partner else { continue }
            let first = definition.name
            let firstValid = values[first] != nil
            let partnerValid = values[partner] != nil
            if firstValid && partnerValid { continue }
            let anyInvalid = invalid.contains(first) || invalid.contains(partner)
            if !firstValid && !partnerValid && !anyInvalid { continue }

            // An invalid member already has its own finding; only report a member that is missing.
            if (firstValid || partnerValid) && !anyInvalid {
                issues.append(ManagedPolicyIssue(
                    key: firstValid ? partner : first,
                    scope: scope,
                    message: "\(first) and \(partner) must both be set at the same scope; the pair is ignored."
                ))
            }
            values[first] = nil
            values[partner] = nil
            invalid.insert(first)
            invalid.insert(partner)
        }
    }

    private struct Problem: Error {
        let message: String
    }

    private static func validate(
        _ raw: ManagedPolicyRawValue,
        as definition: ManagedPolicyDefinition
    ) -> Result<ManagedPolicyValue, Problem> {
        switch definition.kind {
        case .boolean:
            guard case .boolean(let value) = raw else {
                return .failure(Problem(message: "must be a Boolean (<true/> or <false/>)"))
            }
            return .success(.boolean(value))
        case .enumeration:
            guard case .integer(let value) = raw, (0...definition.enumerationMaximum).contains(value) else {
                return .failure(Problem(message: "must be an integer between 0 and \(definition.enumerationMaximum)"))
            }
            return .success(.enumeration(value))
        case .text:
            guard case .string(let string) = raw else {
                return .failure(Problem(message: "must be a string"))
            }
            return validateText(string).map(ManagedPolicyValue.text)
        case .list:
            guard case .array(let entries) = raw else {
                return .failure(Problem(message: "must be an array of strings"))
            }
            var items: [String] = []
            var seen: Set<String> = []
            for entry in entries {
                guard case .string(let string) = entry else {
                    return .failure(Problem(message: "must contain only strings"))
                }
                guard case .success(let item) = validateText(string) else {
                    return .failure(Problem(message: "contains an entry that is empty, too long or has control characters"))
                }
                if seen.insert(item).inserted { items.append(item) }
            }
            guard items.count <= maximumListEntries else {
                return .failure(Problem(message: "must not exceed \(maximumListEntries) entries"))
            }
            return .success(.list(items))
        }
    }

    private static func validateText(_ raw: String) -> Result<String, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(Problem(message: "must not be empty")) }
        if text.count > maximumTextLength {
            return .failure(Problem(message: "must not exceed \(maximumTextLength) characters"))
        }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(Problem(message: "must not contain control characters"))
        }
        return .success(text)
    }
}
