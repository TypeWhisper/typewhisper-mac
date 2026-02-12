import Foundation
import WhisperKit

final class WhisperEngine: TranscriptionEngine {
    let engineType: EngineType = .whisper
    let supportsStreaming = true
    let supportsTranslation = true

    private(set) var isModelLoaded = false
    private var whisperKit: WhisperKit?
    private var currentModelId: String?

    var supportedLanguages: [String] {
        // Whisper supports 99+ languages
        ["de", "en", "fr", "es", "it", "pt", "nl", "pl", "ru", "zh", "ja", "ko", "ar", "hi", "tr", "cs", "sv", "da", "fi", "el", "hu", "ro", "bg", "uk", "hr", "sk", "sl", "et", "lv", "lt"]
    }

    func loadModel(_ model: ModelInfo, progress: @escaping (Double) -> Void) async throws {
        guard model.engineType == .whisper else {
            throw TranscriptionEngineError.modelLoadFailed("Not a Whisper model")
        }

        // Unload previous model if different
        if currentModelId != model.id {
            unloadModel()
        }

        do {
            progress(0.1)

            let config = WhisperKitConfig(
                model: model.id,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )

            progress(0.3)
            whisperKit = try await WhisperKit(config)
            progress(1.0)

            currentModelId = model.id
            isModelLoaded = true
        } catch {
            isModelLoaded = false
            whisperKit = nil
            currentModelId = nil
            throw TranscriptionEngineError.modelLoadFailed(error.localizedDescription)
        }
    }

    func unloadModel() {
        whisperKit = nil
        currentModelId = nil
        isModelLoaded = false
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask
    ) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let whisperTask: DecodingTask = task == .translate ? .translate : .transcribe

        let options = DecodingOptions(
            verbose: false,
            task: whisperTask,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )

        let startTime = CFAbsoluteTimeGetCurrent()

        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: options
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(audioSamples.count) / 16000.0

        let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language

        return TranscriptionResult(
            text: fullText,
            detectedLanguage: detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: .whisper
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        onProgress: @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let whisperTask: DecodingTask = task == .translate ? .translate : .transcribe

        let options = DecodingOptions(
            verbose: false,
            task: whisperTask,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )

        let startTime = CFAbsoluteTimeGetCurrent()

        let results = try await whisperKit.transcribe(
            audioArray: audioSamples,
            decodeOptions: options,
            callback: { progress in
                let shouldContinue = onProgress(progress.text)
                return shouldContinue ? nil : false
            }
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(audioSamples.count) / 16000.0

        let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language

        return TranscriptionResult(
            text: fullText,
            detectedLanguage: detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: .whisper
        )
    }
}
