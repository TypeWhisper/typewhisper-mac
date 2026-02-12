import Foundation

protocol TranscriptionEngine {
    var engineType: EngineType { get }
    var isModelLoaded: Bool { get }
    var supportedLanguages: [String] { get }
    var supportsStreaming: Bool { get }
    var supportsTranslation: Bool { get }

    func loadModel(_ model: ModelInfo, progress: @escaping (Double) -> Void) async throws
    func unloadModel()

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask
    ) async throws -> TranscriptionResult
}

enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case unsupportedTask(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model loaded. Please download and select a model first."
        case .unsupportedTask(let detail):
            "Unsupported task: \(detail)"
        case .transcriptionFailed(let detail):
            "Transcription failed: \(detail)"
        case .modelLoadFailed(let detail):
            "Failed to load model: \(detail)"
        case .modelDownloadFailed(let detail):
            "Failed to download model: \(detail)"
        }
    }
}
