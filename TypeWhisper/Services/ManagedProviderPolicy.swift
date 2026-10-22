import Foundation
import os
import TypeWhisperPluginSDK

/// The cloud, provider, plugin and download restrictions of one policy snapshot, as typed refusals.
///
/// Every method returns nil when the operation may run, otherwise a localized reason. Restrictions
/// apply where content is sent, not only in Settings. Provider IDs follow #1313: a plugin's manifest
/// ID covers every provider the plugin exposes, `<manifest ID>:<provider ID>` names a single one, and
/// built-in providers have reserved IDs. Matching ignores letter case.
struct ManagedProviderPolicy: Equatable, Sendable {
    /// What a provider receives, which decides the cloud key that applies.
    enum Content: Sendable {
        /// Audio sent for transcription: `AllowCloudTranscription`.
        case audio
        /// Transcripts, prompts, vocabulary and context: `AllowCloudTextProcessing`.
        case text
    }

    /// Reserved ID for Apple Intelligence, which runs on the Mac and is built into the app.
    static let appleIntelligenceId = "com.typewhisper.apple-intelligence"

    var allowsCloudTranscription = true
    var allowsCloudTextProcessing = true
    /// nil leaves the list unrestricted; an empty list allows nothing.
    var allowedTranscriptionProviders: [String]?
    var allowedLlmProviders: [String]?
    var allowedPlugins: [String]?
    var allowsModelDownloads = true
    /// Keys whose value is invalid or unreadable; the capabilities they govern stay refused.
    var blockedKeys: Set<String> = []

    static let unmanaged = ManagedProviderPolicy()

    init(
        allowsCloudTranscription: Bool = true,
        allowsCloudTextProcessing: Bool = true,
        allowedTranscriptionProviders: [String]? = nil,
        allowedLlmProviders: [String]? = nil,
        allowedPlugins: [String]? = nil,
        allowsModelDownloads: Bool = true,
        blockedKeys: Set<String> = []
    ) {
        self.allowsCloudTranscription = allowsCloudTranscription
        self.allowsCloudTextProcessing = allowsCloudTextProcessing
        self.allowedTranscriptionProviders = allowedTranscriptionProviders
        self.allowedLlmProviders = allowedLlmProviders
        self.allowedPlugins = allowedPlugins
        self.allowsModelDownloads = allowsModelDownloads
        self.blockedKeys = blockedKeys
    }

    init(snapshot: ManagedPolicySnapshot) {
        func allows(_ key: String) -> Bool {
            snapshot.enforced(key)?.booleanValue ?? true
        }
        allowsCloudTranscription = allows(ManagedPolicyKeys.allowCloudTranscription)
        allowsCloudTextProcessing = allows(ManagedPolicyKeys.allowCloudTextProcessing)
        allowsModelDownloads = allows(ManagedPolicyKeys.allowModelDownloads)
        allowedTranscriptionProviders = snapshot.enforced(ManagedPolicyKeys.allowedTranscriptionProviders)?.listItems
        allowedLlmProviders = snapshot.enforced(ManagedPolicyKeys.allowedLlmProviders)?.listItems
        allowedPlugins = snapshot.enforced(ManagedPolicyKeys.allowedPlugins)?.listItems
        blockedKeys = Set(Self.governedKeys.filter(snapshot.isBlocked))
    }

    private static let governedKeys = [
        ManagedPolicyKeys.allowCloudTranscription, ManagedPolicyKeys.allowCloudTextProcessing,
        ManagedPolicyKeys.allowedTranscriptionProviders, ManagedPolicyKeys.allowedLlmProviders,
        ManagedPolicyKeys.allowedPlugins, ManagedPolicyKeys.allowModelDownloads,
    ]

    var isRestricting: Bool {
        self != .unmanaged
    }

    // MARK: - Packages

    /// Why a plugin may not be installed, loaded or enabled. Checked before any of its code runs.
    ///
    /// Besides `AllowedPlugins`, a plugin that is not local and whose every capability (its manifest
    /// categories) is refused by a cloud key is refused as a whole; a plugin with one allowed
    /// capability loads and its refused capabilities are refused where they are used.
    func packageRefusal(pluginId: String, locality: PluginLocality?, categories: [String]) -> String? {
        if let refusal = pluginAllowlistRefusal(pluginId: pluginId) {
            return refusal
        }
        guard locality != .local, !categories.isEmpty else { return nil }
        let refusals = categories.map { cloudRefusal(Self.content(forCategory: $0), locality: locality) }
        guard let first = refusals.first, let reason = first, refusals.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return reason
    }

    func packageRefusal(for manifest: PluginManifest) -> String? {
        packageRefusal(
            pluginId: manifest.id,
            locality: manifest.resolvedLocality,
            categories: manifest.resolvedCategoryIdentifiers
        )
    }

    /// The `transcription` category sends audio; every other category receives text.
    static func content(forCategory category: String) -> Content {
        category == "transcription" ? .audio : .text
    }

    // MARK: - Use

    /// Why audio may not reach this transcription provider.
    func transcriptionRefusal(pluginId: String, providerId: String, locality: PluginLocality?) -> String? {
        if let refusal = pluginAllowlistRefusal(pluginId: pluginId) {
            return refusal
        }
        if let refusal = providerAllowlistRefusal(
            ManagedPolicyKeys.allowedTranscriptionProviders,
            allowed: allowedTranscriptionProviders,
            pluginId: pluginId,
            providerId: providerId,
            message: String(localized: "Your organization does not allow this transcription provider.")
        ) {
            return refusal
        }
        return cloudRefusal(.audio, locality: locality)
    }

    /// Why text may not reach this language model provider.
    func llmRefusal(pluginId: String, providerId: String, locality: PluginLocality?) -> String? {
        if let refusal = pluginAllowlistRefusal(pluginId: pluginId) {
            return refusal
        }
        if let refusal = providerAllowlistRefusal(
            ManagedPolicyKeys.allowedLlmProviders,
            allowed: allowedLlmProviders,
            pluginId: pluginId,
            providerId: providerId,
            message: String(localized: "Your organization does not allow this language model provider.")
        ) {
            return refusal
        }
        return cloudRefusal(.text, locality: locality)
    }

    /// Why transcript, prompt or context text may not reach this plugin: post-processors, actions,
    /// speech output, memory and event subscribers.
    func textRefusal(pluginId: String, locality: PluginLocality?) -> String? {
        pluginAllowlistRefusal(pluginId: pluginId) ?? cloudRefusal(.text, locality: locality)
    }

    /// Whether dictionary terms may be sent as prompt text with audio for this locality.
    func allowsPromptText(toTranscriptionLocality locality: PluginLocality?) -> Bool {
        cloudRefusal(.text, locality: locality) == nil
    }

    var modelDownloadRefusal: String? {
        if blockedKeys.contains(ManagedPolicyKeys.allowModelDownloads) {
            return Self.blockedMessage
        }
        return allowsModelDownloads ? nil : String(localized: "Your organization does not allow model downloads.")
    }

    // MARK: - Rules

    func cloudRefusal(_ content: Content, locality: PluginLocality?) -> String? {
        let key = content == .audio ? ManagedPolicyKeys.allowCloudTranscription : ManagedPolicyKeys.allowCloudTextProcessing
        if blockedKeys.contains(key) {
            return Self.blockedMessage
        }
        let allowed = content == .audio ? allowsCloudTranscription : allowsCloudTextProcessing
        // Cloud, configurable and unknown localities are all refused: only `local` is known to stay on the Mac.
        guard !allowed, locality != .local else { return nil }
        return content == .audio
            ? String(localized: "Your organization does not allow audio to be transcribed outside this Mac.")
            : String(localized: "Your organization does not allow text to be processed outside this Mac.")
    }

    private func pluginAllowlistRefusal(pluginId: String) -> String? {
        if blockedKeys.contains(ManagedPolicyKeys.allowedPlugins) {
            return Self.blockedMessage
        }
        guard let allowedPlugins, pluginId != Self.appleIntelligenceId else { return nil }
        return allowedPlugins.contains(where: { Self.matches($0, pluginId) })
            ? nil
            : String(localized: "Your organization does not allow this plugin.")
    }

    private func providerAllowlistRefusal(
        _ key: String,
        allowed: [String]?,
        pluginId: String,
        providerId: String,
        message: String
    ) -> String? {
        if blockedKeys.contains(key) {
            return Self.blockedMessage
        }
        guard let allowed else { return nil }
        let qualified = "\(pluginId):\(providerId)"
        return allowed.contains(where: { Self.matches($0, pluginId) || Self.matches($0, qualified) }) ? nil : message
    }

    private static func matches(_ entry: String, _ identifier: String) -> Bool {
        entry.caseInsensitiveCompare(identifier) == .orderedSame
    }

    static var blockedMessage: String {
        String(localized: "This waits until your organization's settings can be applied.")
    }
}

/// An operation the managed settings refuse. Its description is the localized reason.
struct ManagedPolicyRefusal: LocalizedError, Equatable, Sendable {
    let reason: String

    var errorDescription: String? { reason }
}

/// The latest snapshot for callers outside the main actor, such as plugins asking `HostServices`
/// whether they may download.
final class ManagedPolicySnapshotStore: Sendable {
    static let shared = ManagedPolicySnapshotStore()

    private let state: OSAllocatedUnfairLock<ManagedPolicySnapshot>

    init(_ snapshot: ManagedPolicySnapshot = .empty) {
        state = OSAllocatedUnfairLock(initialState: snapshot)
    }

    var current: ManagedPolicySnapshot {
        state.withLock { $0 }
    }

    var providerPolicy: ManagedProviderPolicy {
        ManagedProviderPolicy(snapshot: current)
    }

    func update(_ snapshot: ManagedPolicySnapshot) {
        state.withLock { $0 = snapshot }
    }
}
