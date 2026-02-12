import Foundation
import FluidAudio

final class ParakeetEngine: TranscriptionEngine {
    let engineType: EngineType = .parakeet
    let supportsStreaming = false
    let supportsTranslation = false

    private(set) var isModelLoaded = false
    private var asrManager: AsrManager?

    var supportedLanguages: [String] {
        // Parakeet TDT v3: 25 European languages
        ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    }

    func loadModel(_ model: ModelInfo, progress: @escaping (Double) -> Void) async throws {
        guard model.engineType == .parakeet else {
            throw TranscriptionEngineError.modelLoadFailed("Not a Parakeet model")
        }

        do {
            progress(0.1)

            let models = try await AsrModels.downloadAndLoad(version: .v3)
            progress(0.7)

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            progress(1.0)

            asrManager = manager
            isModelLoaded = true
        } catch {
            isModelLoaded = false
            asrManager = nil
            throw TranscriptionEngineError.modelLoadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        asrManager = nil
        isModelLoaded = false
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask
    ) async throws -> TranscriptionResult {
        guard let asrManager else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        if task == .translate {
            throw TranscriptionEngineError.unsupportedTask("Parakeet does not support translation")
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let result = try await asrManager.transcribe(audioSamples, source: .system)

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(audioSamples.count) / 16000.0

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: nil,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: .parakeet
        )
    }
}
