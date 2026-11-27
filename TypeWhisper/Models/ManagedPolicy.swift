import Foundation
import os

/// The value shape of a managed policy key.
enum ManagedPolicyValueKind: String, Sendable {
    /// A property list Boolean.
    case boolean
    /// A property list integer within a key-specific range that starts at 0.
    case enumeration
    /// A trimmed, nonempty string without control characters.
    case text
    /// An array of such strings. An empty array denies everything.
    case list
}

/// Where a managed policy value is declared.
enum ManagedPolicyScope: String, Sendable {
    /// A root key of the managed preferences: a value users cannot change.
    case enforced
    /// An entry of the managed `Recommended` dictionary: an administrator default users may change.
    case recommended
}

/// Whether the policy source could be read and whether it holds anything.
enum ManagedPolicyReadStatus: String, Sendable {
    /// The source was read and contains no policy keys.
    case absent
    /// The source was read and contains at least one policy key.
    case present
    /// The source could not be read. Retained values may be stale and managed operations should wait.
    case unreadable
}

/// Describes one supported managed policy key.
struct ManagedPolicyDefinition: Sendable, Equatable {
    /// The exact, case-sensitive preference key.
    let name: String
    let kind: ManagedPolicyValueKind
    /// Whether the key may appear in `Recommended`. Restrictions may not.
    var allowsRecommendation = false
    /// The largest valid enumeration value.
    var enumerationMaximum = 0
    /// A key that must be present at the same scope.
    var pairedWith: String?
    /// Whether the value must never appear in diagnostics, logs or exports.
    var sensitive = false
    /// Whether a value written outside a configuration profile is a supported input of the
    /// key's own feature, so the policy reader should not report it.
    var acceptsUnmanagedValue = false
}

/// The managed preference keys shared with TypeWhisper for Windows (typewhisper-win#470, #641).
/// Names, value meanings and precedence match the registry policies of the Windows app.
enum ManagedPolicyKeys {
    /// The managed dictionary that holds recommendations instead of enforced values.
    static let recommendedDictionary = "Recommended"

    static let transcriptionProviderId = "TranscriptionProviderId"
    static let transcriptionModelId = "TranscriptionModelId"
    static let llmProviderId = "LlmProviderId"
    static let llmModelId = "LlmModelId"
    static let allowedTranscriptionProviders = "AllowedTranscriptionProviders"
    static let allowedLlmProviders = "AllowedLlmProviders"
    static let allowedPlugins = "AllowedPlugins"
    static let allowCloudTranscription = "AllowCloudTranscription"
    static let allowCloudTextProcessing = "AllowCloudTextProcessing"
    static let allowPluginDownloads = "AllowPluginDownloads"
    static let allowModelDownloads = "AllowModelDownloads"
    /// 0 = External, 1 = CheckOnly, 2 = UserInitiated.
    static let updateMode = "UpdateMode"
    /// 0 = Stable, 1 = Daily, 2 = ReleaseCandidate.
    static let updateChannel = "UpdateChannel"
    static let allowedUpdateChannels = "AllowedUpdateChannels"
    static let launchAtLogin = "LaunchAtLogin"
    static let skipOnboardingWhenReady = "SkipOnboardingWhenReady"
    static let suppressOptionalPrompts = "SuppressOptionalPrompts"
    /// Mac only: whether Ask History and its search index may be used.
    static let allowHistoryAsk = "AllowHistoryAsk"
    /// `false` keeps API keys on this Mac: API key sync through iCloud Keychain stays off.
    static let allowAPIKeySync = "AllowAPIKeySync"
    /// Read by `LicenseService` since 1.6.1, which also accepts values set with `defaults write`.
    static let managedLicenseKey = UserDefaultsKeys.managedLicenseKey

    /// Every supported key: the app's own in documentation order, then the keys of modules.
    static var all: [ManagedPolicyDefinition] { hostDefinitions + moduleDefinitions }

    /// The app's own keys in documentation order.
    static let hostDefinitions: [ManagedPolicyDefinition] = [
        .init(name: transcriptionProviderId, kind: .text, allowsRecommendation: true, pairedWith: transcriptionModelId),
        .init(name: transcriptionModelId, kind: .text, allowsRecommendation: true, pairedWith: transcriptionProviderId),
        .init(name: llmProviderId, kind: .text, allowsRecommendation: true, pairedWith: llmModelId),
        .init(name: llmModelId, kind: .text, allowsRecommendation: true, pairedWith: llmProviderId),
        .init(name: allowedTranscriptionProviders, kind: .list),
        .init(name: allowedLlmProviders, kind: .list),
        .init(name: allowedPlugins, kind: .list),
        .init(name: allowCloudTranscription, kind: .boolean),
        .init(name: allowCloudTextProcessing, kind: .boolean),
        .init(name: allowPluginDownloads, kind: .boolean),
        .init(name: allowModelDownloads, kind: .boolean),
        .init(name: updateMode, kind: .enumeration, enumerationMaximum: 2),
        .init(name: updateChannel, kind: .enumeration, allowsRecommendation: true, enumerationMaximum: 2),
        .init(name: allowedUpdateChannels, kind: .list),
        .init(name: launchAtLogin, kind: .boolean, allowsRecommendation: true),
        .init(name: skipOnboardingWhenReady, kind: .boolean),
        .init(name: suppressOptionalPrompts, kind: .boolean, allowsRecommendation: true),
        .init(name: allowHistoryAsk, kind: .boolean),
        .init(name: allowAPIKeySync, kind: .boolean),
        .init(name: managedLicenseKey, kind: .text, sensitive: true, acceptsUnmanagedValue: true),
    ]

    private static let byName = Dictionary(uniqueKeysWithValues: hostDefinitions.map { ($0.name, $0) })
    private struct ModuleKeys {
        var definitions: [ManagedPolicyDefinition] = []
        /// The app's own keys that modules declared too, to read them.
        var sharedHostKeys: Set<String> = []
    }

    private static let moduleStore = OSAllocatedUnfairLock(initialState: ModuleKeys())

    /// The keys the app's modules declared, in their order, without the app's own.
    static var moduleDefinitions: [ManagedPolicyDefinition] {
        moduleStore.withLock { $0.definitions }
    }

    /// Whether a module declared the key: one of its own, or one of the app's that it reads too.
    static func isDeclaredByModule(_ name: String) -> Bool {
        moduleStore.withLock { state in
            state.sharedHostKeys.contains(name) || state.definitions.contains { $0.name == name }
        }
    }

    /// Replaces the keys of modules. A module may declare one of the app's keys with the same
    /// kind to read it; the app keeps its own definition. A key without a name, with the name
    /// of `Recommended`, of an earlier key or of profile metadata, or one that matches an
    /// app's key only in letter case or not in kind, is left out.
    /// - Returns: The names that were left out.
    @discardableResult
    static func setModuleDefinitions(_ definitions: [ManagedPolicyDefinition]) -> [String] {
        var accepted: [ManagedPolicyDefinition] = []
        var shared: Set<String> = []
        var names = Set(byName.keys).union([recommendedDictionary])
        var rejected: [String] = []
        for definition in definitions {
            let name = definition.name
            if let hostDefinition = byName[name] {
                if hostDefinition.kind == definition.kind {
                    shared.insert(name)
                } else {
                    rejected.append(name)
                }
                continue
            }
            guard !name.isEmpty, !ManagedPolicyValidator.isProfileMetadataKey(name),
                  definition.enumerationMaximum >= 0,
                  !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                rejected.append(name)
                continue
            }
            names.insert(name)
            // The app's pairs and its own unmanaged inputs stay the app's.
            accepted.append(ManagedPolicyDefinition(
                name: name,
                kind: definition.kind,
                allowsRecommendation: definition.allowsRecommendation,
                enumerationMaximum: definition.enumerationMaximum,
                sensitive: definition.sensitive
            ))
        }
        let keys = ModuleKeys(definitions: accepted, sharedHostKeys: shared)
        moduleStore.withLock { $0 = keys }
        return rejected
    }

    /// Finds a definition by its exact name, or nil for an unknown key.
    static func definition(named name: String) -> ManagedPolicyDefinition? {
        byName[name] ?? moduleStore.withLock { $0.definitions.first { $0.name == name } }
    }

    /// The supported key that differs from `name` only in letter case, for diagnostics.
    static func caseInsensitiveMatch(for name: String) -> String? {
        let candidates = all.map(\.name) + [recommendedDictionary]
        return candidates.first { $0 != name && $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// A validated policy value.
enum ManagedPolicyValue: Sendable, Equatable {
    case boolean(Bool)
    case enumeration(Int)
    case text(String)
    case list([String])

    var kind: ManagedPolicyValueKind {
        switch self {
        case .boolean: .boolean
        case .enumeration: .enumeration
        case .text: .text
        case .list: .list
        }
    }

    var booleanValue: Bool? {
        if case .boolean(let value) = self { value } else { nil }
    }

    var enumerationValue: Int? {
        if case .enumeration(let value) = self { value } else { nil }
    }

    var textValue: String? {
        if case .text(let value) = self { value } else { nil }
    }

    var listItems: [String]? {
        if case .list(let items) = self { items } else { nil }
    }
}

/// A validation finding about the policy source. Messages name keys, never values.
struct ManagedPolicyIssue: Sendable, Equatable {
    /// The affected key, or nil for the source as a whole.
    let key: String?
    /// The affected scope, or nil for the source as a whole.
    let scope: ManagedPolicyScope?
    /// A technical English description for diagnostics.
    let message: String
}

/// An immutable, validated view of the managed preferences at one point in time.
///
/// Consumers check `isBlocked(_:)` before relying on a resolved value: an unreadable source or an
/// invalid enforced value must block the affected capability instead of relaxing it.
struct ManagedPolicySnapshot: Sendable {
    /// The state before the first read: revision 0 and no policy.
    static let empty = ManagedPolicySnapshot(
        revision: 0,
        status: .absent,
        readAt: .distantPast,
        enforcedValues: [:],
        recommendedValues: [:],
        invalidEnforcedKeys: [],
        issues: []
    )

    /// Increases whenever published content changes.
    let revision: Int
    let status: ManagedPolicyReadStatus
    let readAt: Date
    /// Valid enforced values by key name.
    let enforcedValues: [String: ManagedPolicyValue]
    /// Valid recommended values by key name.
    let recommendedValues: [String: ManagedPolicyValue]
    /// Keys whose enforced value is present but invalid; their capabilities stay blocked.
    let invalidEnforcedKeys: Set<String>
    /// Validation findings for diagnostics.
    let issues: [ManagedPolicyIssue]

    /// Whether any policy applies, including invalid enforced keys.
    var isManaged: Bool {
        !enforcedValues.isEmpty || !recommendedValues.isEmpty || !invalidEnforcedKeys.isEmpty
    }

    func enforced(_ key: String) -> ManagedPolicyValue? {
        enforcedValues[key]
    }

    func recommended(_ key: String) -> ManagedPolicyValue? {
        recommendedValues[key]
    }

    func isEnforced(_ key: String) -> Bool {
        enforcedValues[key] != nil
    }

    /// Whether the capability behind a key must stay blocked: the source is unreadable or its
    /// enforced value is invalid.
    func isBlocked(_ key: String) -> Bool {
        status == .unreadable || invalidEnforcedKeys.contains(key)
    }

    /// Resolves a Boolean key by precedence. Check `isBlocked(_:)` first.
    func resolveBoolean(
        _ key: String,
        applicationDefault: Bool,
        userPreference: Bool? = nil
    ) -> ResolvedManagedSetting<Bool> {
        expect(key, .boolean)
        return ManagedSettingResolver.resolve(
            applicationDefault: applicationDefault,
            explicitUserPreference: userPreference,
            recommendedPolicy: recommended(key)?.booleanValue,
            enforcedPolicy: enforced(key)?.booleanValue
        )
    }

    /// Resolves an enumeration key by precedence. Check `isBlocked(_:)` first.
    func resolveEnumeration(
        _ key: String,
        applicationDefault: Int,
        userPreference: Int? = nil
    ) -> ResolvedManagedSetting<Int> {
        expect(key, .enumeration)
        return ManagedSettingResolver.resolve(
            applicationDefault: applicationDefault,
            explicitUserPreference: userPreference,
            recommendedPolicy: recommended(key)?.enumerationValue,
            enforcedPolicy: enforced(key)?.enumerationValue
        )
    }

    /// Resolves a text key by precedence. Check `isBlocked(_:)` first.
    func resolveText(
        _ key: String,
        applicationDefault: String,
        userPreference: String? = nil
    ) -> ResolvedManagedSetting<String> {
        expect(key, .text)
        return ManagedSettingResolver.resolve(
            applicationDefault: applicationDefault,
            explicitUserPreference: userPreference,
            recommendedPolicy: recommended(key)?.textValue,
            enforcedPolicy: enforced(key)?.textValue
        )
    }

    /// Keeps this snapshot's status, revision and issues but the values of an earlier snapshot.
    func retainingValues(from previous: ManagedPolicySnapshot) -> ManagedPolicySnapshot {
        ManagedPolicySnapshot(
            revision: revision,
            status: status,
            readAt: readAt,
            enforcedValues: previous.enforcedValues,
            recommendedValues: previous.recommendedValues,
            invalidEnforcedKeys: previous.invalidEnforcedKeys,
            issues: issues
        )
    }

    /// Compares everything except `revision` and `readAt`.
    func contentEquals(_ other: ManagedPolicySnapshot) -> Bool {
        status == other.status
            && enforcedValues == other.enforcedValues
            && recommendedValues == other.recommendedValues
            && invalidEnforcedKeys == other.invalidEnforcedKeys
            && issues == other.issues
    }

    private func expect(_ key: String, _ kind: ManagedPolicyValueKind) {
        precondition(
            ManagedPolicyKeys.definition(named: key)?.kind == kind,
            "\(key) is not a \(kind.rawValue) managed policy key"
        )
    }
}

/// Identifies the source of an effective managed preference.
enum ManagedSettingSource: String, Sendable {
    /// The application's built-in default.
    case applicationDefault
    /// An editable administrator recommendation.
    case recommendedPolicy
    /// A value explicitly selected by the user, including a factory-default value.
    case userPreference
    /// A mandatory administrator setting.
    case enforcedPolicy
}

/// An effective preference for consumption, separate from stored user settings.
struct ResolvedManagedSetting<Value: Sendable & Equatable>: Sendable, Equatable {
    let value: Value
    let source: ManagedSettingSource

    /// Whether the effective setting is fixed by an administrator.
    var isEnforced: Bool { source == .enforcedPolicy }
}

/// Resolves validated managed preferences without reading or writing user settings.
///
/// This is only the precedence layer for preferences that support recommendations. Validation,
/// restriction intersection and runtime enforcement belong to separate layers. An invalid or
/// unreadable enforced policy must not be passed as absent.
enum ManagedSettingResolver {
    /// Selects enforced policy, explicit user choice, recommendation, then application default.
    /// A nil argument means that source has no value; false or zero are still explicit values.
    /// Do not persist the result over the user's choice.
    static func resolve<Value>(
        applicationDefault: Value,
        explicitUserPreference: Value? = nil,
        recommendedPolicy: Value? = nil,
        enforcedPolicy: Value? = nil
    ) -> ResolvedManagedSetting<Value> {
        if let enforcedPolicy {
            return ResolvedManagedSetting(value: enforcedPolicy, source: .enforcedPolicy)
        }
        if let explicitUserPreference {
            return ResolvedManagedSetting(value: explicitUserPreference, source: .userPreference)
        }
        if let recommendedPolicy {
            return ResolvedManagedSetting(value: recommendedPolicy, source: .recommendedPolicy)
        }
        return ResolvedManagedSetting(value: applicationDefault, source: .applicationDefault)
    }
}
