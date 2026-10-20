import Foundation

/// A provider and model named by `TranscriptionProviderId`/`TranscriptionModelId` or
/// `LlmProviderId`/`LlmModelId`. The provider is a plugin ID, `<plugin ID>:<provider ID>`,
/// or a reserved built-in ID.
struct ManagedSelectionPair: Equatable, Sendable {
    let providerId: String
    let modelId: String

    /// The plugin ID and, for `<plugin ID>:<provider ID>`, the provider within it.
    var components: (pluginId: String, providerId: String?) {
        guard let separator = providerId.firstIndex(of: ":") else { return (providerId, nil) }
        let pluginId = String(providerId[..<separator])
        let provider = String(providerId[providerId.index(after: separator)...])
        return (pluginId, provider.isEmpty ? nil : provider)
    }
}

/// The provider and model pairs of one policy snapshot.
///
/// An enforced pair fixes the provider and model for every entry point and never falls back; a
/// recommended pair is the initial selection of a profile that has not chosen one. An incomplete or
/// invalid enforced pair blocks its capability until it is corrected.
struct ManagedSelectionPolicy: Equatable, Sendable {
    var enforcedTranscription: ManagedSelectionPair?
    var recommendedTranscription: ManagedSelectionPair?
    var enforcedLlm: ManagedSelectionPair?
    var recommendedLlm: ManagedSelectionPair?
    var isTranscriptionBlocked = false
    var isLlmBlocked = false

    static let unmanaged = ManagedSelectionPolicy()

    init(
        enforcedTranscription: ManagedSelectionPair? = nil,
        recommendedTranscription: ManagedSelectionPair? = nil,
        enforcedLlm: ManagedSelectionPair? = nil,
        recommendedLlm: ManagedSelectionPair? = nil,
        isTranscriptionBlocked: Bool = false,
        isLlmBlocked: Bool = false
    ) {
        self.enforcedTranscription = enforcedTranscription
        self.recommendedTranscription = recommendedTranscription
        self.enforcedLlm = enforcedLlm
        self.recommendedLlm = recommendedLlm
        self.isTranscriptionBlocked = isTranscriptionBlocked
        self.isLlmBlocked = isLlmBlocked
    }

    init(snapshot: ManagedPolicySnapshot) {
        func pair(_ provider: String, _ model: String, scope: ManagedPolicyScope) -> ManagedSelectionPair? {
            let values = scope == .enforced ? snapshot.enforcedValues : snapshot.recommendedValues
            guard let providerId = values[provider]?.textValue, let modelId = values[model]?.textValue else { return nil }
            return ManagedSelectionPair(providerId: providerId, modelId: modelId)
        }
        let transcription = (ManagedPolicyKeys.transcriptionProviderId, ManagedPolicyKeys.transcriptionModelId)
        let llm = (ManagedPolicyKeys.llmProviderId, ManagedPolicyKeys.llmModelId)
        enforcedTranscription = pair(transcription.0, transcription.1, scope: .enforced)
        recommendedTranscription = pair(transcription.0, transcription.1, scope: .recommended)
        enforcedLlm = pair(llm.0, llm.1, scope: .enforced)
        recommendedLlm = pair(llm.0, llm.1, scope: .recommended)
        isTranscriptionBlocked = snapshot.isBlocked(transcription.0) || snapshot.isBlocked(transcription.1)
        isLlmBlocked = snapshot.isBlocked(llm.0) || snapshot.isBlocked(llm.1)
    }

    var enforcesTranscription: Bool {
        enforcedTranscription != nil || isTranscriptionBlocked
    }

    var enforcesLlm: Bool {
        enforcedLlm != nil || isLlmBlocked
    }
}

/// How an enforced or recommended pair maps to what is installed.
enum ManagedPairResolution: Equatable, Sendable {
    /// The provider ID and model ID the app uses internally.
    case resolved(providerId: String, modelId: String)
    /// Why the pair cannot be used right now, localized.
    case unavailable(String)

    var resolvedProviderId: String? {
        if case .resolved(let providerId, _) = self { providerId } else { nil }
    }

    var resolvedModelId: String? {
        if case .resolved(_, let modelId) = self { modelId } else { nil }
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }
}
