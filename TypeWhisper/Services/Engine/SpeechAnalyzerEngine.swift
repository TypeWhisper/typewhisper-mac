import Foundation
@preconcurrency import AVFoundation
import Speech
import os

// MARK: - Model Provider

@available(macOS 26, *)
struct SpeechAnalyzerModelProvider {
    static func availableModels() -> [ModelInfo] {
        cachedModels
    }

    nonisolated(unsafe) private static var cachedModels: [ModelInfo] = []

    static func populateCache() async {
        let locales = await SpeechTranscriber.supportedLocales
        cachedModels = locales.compactMap { locale in
            let localeId = locale.identifier
            guard !localeId.isEmpty else { return nil }
            let name = Locale.current.localizedString(forIdentifier: localeId) ?? localeId
            return ModelInfo(
                id: "speechanalyzer-\(localeId)",
                engineType: .speechAnalyzer,
                displayName: name,
                sizeDescription: String(localized: "System-managed"),
                estimatedSizeMB: 0,
                languageCount: 1
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Engine

@available(macOS 26, *)
final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    let engineType: EngineType = .speechAnalyzer
    let supportsStreaming = true
    let supportsTranslation = false

    private(set) var isModelLoaded = false
    private var currentLocale: Locale?

    var supportedLanguages: [String] {
        // Return all languages from cached SpeechAnalyzer models
        let models = SpeechAnalyzerModelProvider.availableModels()
        let codes = Set(models.compactMap { model -> String? in
            let localeId = String(model.id.dropFirst("speechanalyzer-".count))
            return Locale(identifier: localeId).language.languageCode?.identifier
        })
        return Array(codes)
    }

    func loadModel(_ model: ModelInfo, progress: @Sendable @escaping (Double, Double?) -> Void) async throws {
        guard model.engineType == .speechAnalyzer else {
            throw TranscriptionEngineError.modelLoadFailed("Not a SpeechAnalyzer model")
        }

        let localeId = String(model.id.dropFirst("speechanalyzer-".count))
        let locale = Locale(identifier: localeId)

        progress(0.1, nil)

        // Verify locale is supported
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier == locale.identifier }) else {
            throw TranscriptionEngineError.modelLoadFailed(
                String(localized: "Language not supported by Apple Speech"))
        }

        progress(0.2, nil)

        // Create temporary transcriber for asset check
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Download assets if needed
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let downloadProgress = downloader.progress
            let progressTask = Task.detached { [downloadProgress] in
                while !downloadProgress.isFinished && !Task.isCancelled {
                    let fraction = 0.2 + downloadProgress.fractionCompleted * 0.6
                    progress(fraction, nil)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            try await downloader.downloadAndInstall()
            progressTask.cancel()
        }

        progress(0.9, nil)

        try await AssetInventory.reserve(locale: locale)

        currentLocale = locale
        isModelLoaded = true

        progress(1.0, nil)
    }

    func unloadModel() {
        if let locale = currentLocale {
            Task { await AssetInventory.release(reservedLocale: locale) }
        }
        currentLocale = nil
        isModelLoaded = false
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask
    ) async throws -> TranscriptionResult {
        guard let locale = currentLocale else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        if task == .translate {
            throw TranscriptionEngineError.unsupportedTask("Apple Speech does not support translation")
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audioDuration = Double(audioSamples.count) / 16000.0

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let buffer = await Self.prepareBuffer(audioSamples, for: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // Collect results concurrently
        let resultTask = Task<String, Error> {
            var fullText = ""
            for try await result in transcriber.results {
                if result.isFinal {
                    fullText += String(result.text.characters)
                }
            }
            return fullText
        }

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await resultTask.value
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        return TranscriptionResult(
            text: text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            detectedLanguage: locale.language.languageCode?.identifier,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: .speechAnalyzer,
            segments: []
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        guard let locale = currentLocale else {
            throw TranscriptionEngineError.modelNotLoaded
        }
        if task == .translate {
            throw TranscriptionEngineError.unsupportedTask("Apple Speech does not support translation")
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audioDuration = Double(audioSamples.count) / 16000.0

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let buffer = await Self.prepareBuffer(audioSamples, for: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let resultTask = Task<String, Error> {
            var fullText = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    fullText += text
                } else {
                    let combined = fullText + text
                    if !onProgress(combined) { break }
                }
            }
            return fullText
        }

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await resultTask.value
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        return TranscriptionResult(
            text: text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            detectedLanguage: locale.language.languageCode?.identifier,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: .speechAnalyzer,
            segments: []
        )
    }

    // MARK: - Audio Helpers

    nonisolated static func createBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private static func prepareBuffer(
        _ samples: [Float],
        for modules: [SpeechTranscriber]
    ) async -> AVAudioPCMBuffer {
        let sourceBuffer = createBuffer(from: samples)

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            return sourceBuffer
        }

        guard sourceBuffer.format != targetFormat else {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
            return sourceBuffer
        }

        let sampleRateRatio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(
            (Double(sourceBuffer.frameLength) * sampleRateRatio).rounded(.up)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: frameCapacity
        ) else {
            return sourceBuffer
        }

        let consumedLock = OSAllocatedUnfairLock(initialState: false)
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, statusPtr in
            let wasConsumed = consumedLock.withLock { consumed in
                let prev = consumed
                consumed = true
                return prev
            }
            if wasConsumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            statusPtr.pointee = .haveData
            return sourceBuffer
        }

        if conversionError != nil {
            return sourceBuffer
        }

        return convertedBuffer
    }
}
