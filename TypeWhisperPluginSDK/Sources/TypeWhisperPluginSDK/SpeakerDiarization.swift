import Foundation

// MARK: - Speaker Diarization Provider Plugin

/// A stretch of audio that a diarization provider attributes to one speaker.
public struct PluginSpeakerTurn: Sendable, Equatable {
    /// Provider-local label, stable within one result. The host renumbers speakers.
    public let speakerLabel: String
    public let start: Double
    public let end: Double

    public init(speakerLabel: String, start: Double, end: Double) {
        self.speakerLabel = speakerLabel
        self.start = start
        self.end = end
    }
}

public struct PluginDiarizationRequest: Sendable {
    /// Host-owned local audio file. Only valid for the duration of the call.
    public let audioURL: URL
    public let duration: TimeInterval
    /// A fixed number of speakers, or nil to detect it.
    public let speakerCount: Int?

    public init(audioURL: URL, duration: TimeInterval, speakerCount: Int? = nil) {
        self.audioURL = audioURL
        self.duration = duration
        self.speakerCount = speakerCount
    }
}

public struct PluginDiarizationResult: Sendable {
    /// Empty when the audio contains no speech.
    public let turns: [PluginSpeakerTurn]
    /// One voice embedding per `speakerLabel`; empty when the provider has none.
    public let speakerEmbeddings: [String: [Float]]
    /// Stable identifier of the model that produced `speakerEmbeddings`, such
    /// as `fluidaudio-offline-diarizer.community-1`. Embeddings of different
    /// models are never compared; change it whenever the vectors change.
    /// Nil uses `engine`.
    public let speakerEmbeddingModel: String?
    /// Stable identifier such as `fluidaudio-offline-diarizer`, not a display name.
    public let engine: String
    public let modelVersion: String?

    public init(
        turns: [PluginSpeakerTurn],
        speakerEmbeddings: [String: [Float]] = [:],
        speakerEmbeddingModel: String? = nil,
        engine: String,
        modelVersion: String? = nil
    ) {
        self.turns = turns
        self.speakerEmbeddings = speakerEmbeddings
        self.speakerEmbeddingModel = speakerEmbeddingModel
        self.engine = engine
        self.modelVersion = modelVersion
    }
}

public enum PluginDiarizationError: Error, Sendable, Equatable {
    /// The models are not installed; the host offers `prepareDiarizationModels`.
    case modelsNotInstalled
    case unsupportedSpeakerCount(Int)
    case processingFailed(String)
}

/// Optional plugin capability for telling who spoke when in a recording.
///
/// The host owns the audio file, the alignment with transcription timing, and
/// the access check. The provider owns its models and the inference.
public protocol SpeakerDiarizationProviderPlugin: TypeWhisperPlugin {
    var diarizationProviderId: String { get }
    var diarizationProviderDisplayName: String { get }
    /// True when `diarize` can run without downloading anything.
    var areDiarizationModelsInstalled: Bool { get }
    /// Fixed speaker counts the provider accepts besides automatic detection.
    var supportedSpeakerCounts: ClosedRange<Int> { get }

    /// Downloads and validates the models. Progress runs from 0 to 1.
    func prepareDiarizationModels(onProgress: @Sendable @escaping (Double) -> Void) async throws
    /// Unloads the models and removes them from disk.
    func deleteDiarizationModels() async throws
    /// Frees loaded models; they load again on the next `diarize`.
    func unloadDiarizationModels() async

    /// Progress runs from 0 to 1. Throws `CancellationError` when the task is cancelled.
    func diarize(
        _ request: PluginDiarizationRequest,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult
}
