import Foundation

// MARK: - Spoken Language Identification Provider Plugin

/// The language a provider heard, chosen among the candidates the host asked about.
public struct PluginSpokenLanguageIdentification: Sendable, Equatable {
    /// One of the candidate codes, exactly as the host passed it.
    public let language: String
    /// Probability of `language` among the candidates, from 0 to 1.
    public let confidence: Double
    /// Probability gap between `language` and the runner-up among the candidates, from 0 to 1.
    public let margin: Double

    public init(language: String, confidence: Double, margin: Double) {
        self.language = language
        self.confidence = confidence
        self.margin = margin
    }
}

/// Optional plugin capability for telling which language is spoken in a recording.
///
/// The host asks when the user selected several languages and the transcription engine accepts
/// only one. The provider owns its model and the inference; the audio must stay on the Mac.
public protocol SpokenLanguageIdentificationProviderPlugin: TypeWhisperPlugin {
    /// Stable identifier such as `typewhisper-ear`, not a display name.
    var spokenLanguageIdentificationProviderId: String { get }

    /// Picks the spoken language among `candidates` (ISO 639-1 codes such as `de`, region or
    /// script suffixes allowed). `samples` are 16 kHz mono; the provider decides how much of
    /// them it needs. Returns nil when fewer than two candidates are languages it knows, so the
    /// host keeps its own choice.
    func identifySpokenLanguage(
        samples: [Float],
        among candidates: [String]
    ) async throws -> PluginSpokenLanguageIdentification?
}
