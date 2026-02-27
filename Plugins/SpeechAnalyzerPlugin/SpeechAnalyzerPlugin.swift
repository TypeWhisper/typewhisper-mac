import Foundation
import SwiftUI
@preconcurrency import AVFoundation
import Speech
import TypeWhisperPluginSDK
import os

// MARK: - Plugin Entry Point

@available(macOS 26, *)
@objc(SpeechAnalyzerPlugin)
final class SpeechAnalyzerPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.speechanalyzer"
    static let pluginName = "Apple Speech"

    fileprivate var host: HostServices?
    fileprivate var currentLocale: Locale?
    fileprivate var loadedModelId: String?
    fileprivate var modelState: SpeechModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0
    fileprivate var cachedModels: [SpeechModelDef] = []
    private var releaseTask: Task<Void, Never>?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        Task { await populateModels() }
        Task { await restoreLoadedModel() }
    }

    func deactivate() {
        if let locale = currentLocale {
            releaseTask = Task { await AssetInventory.release(reservedLocale: locale) }
        }
        currentLocale = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "speechAnalyzer" }
    var providerDisplayName: String { "Apple Speech" }

    var isConfigured: Bool {
        currentLocale != nil && loadedModelId != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return cachedModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName, sizeDescription: "System-managed", languageCount: 1) }
    }

    var selectedModelId: String? { loadedModelId }

    func selectModel(_ modelId: String) {
        // Selecting a different model requires unloading and reloading
        if modelId != loadedModelId, let modelDef = cachedModels.first(where: { $0.id == modelId }) {
            Task { await loadModel(modelDef) }
        }
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }

    var supportedLanguages: [String] {
        let codes = Set(cachedModels.compactMap { model -> String? in
            let localeId = String(model.id.dropFirst("speechanalyzer-".count))
            return Locale(identifier: localeId).language.languageCode?.identifier
        })
        return Array(codes)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let locale = currentLocale else {
            throw PluginTranscriptionError.notConfigured
        }
        if translate {
            throw PluginTranscriptionError.apiError("Apple Speech does not support translation")
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let buffer = await Self.prepareBuffer(audio.samples, for: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

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

        return PluginTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: locale.language.languageCode?.identifier
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let locale = currentLocale else {
            throw PluginTranscriptionError.notConfigured
        }
        if translate {
            throw PluginTranscriptionError.apiError("Apple Speech does not support translation")
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let buffer = await Self.prepareBuffer(audio.samples, for: [transcriber])

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

        return PluginTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: locale.language.languageCode?.identifier
        )
    }

    // MARK: - Model Management

    fileprivate func populateModels() async {
        let locales = await SpeechTranscriber.supportedLocales
        cachedModels = locales.compactMap { locale in
            let localeId = locale.identifier
            guard !localeId.isEmpty else { return nil }
            let name = Locale.current.localizedString(forIdentifier: localeId) ?? localeId
            return SpeechModelDef(id: "speechanalyzer-\(localeId)", displayName: name, locale: locale)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    fileprivate func loadModel(_ modelDef: SpeechModelDef) async {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            // Wait for any pending release
            await releaseTask?.value

            downloadProgress = 0.2

            let transcriber = SpeechTranscriber(locale: modelDef.locale, preset: .transcription)

            // Download assets if needed
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let downloadProgressObj = downloader.progress
                let progressTask = Task.detached { [downloadProgressObj] in
                    while !downloadProgressObj.isFinished && !Task.isCancelled {
                        let fraction = 0.2 + downloadProgressObj.fractionCompleted * 0.6
                        self.downloadProgress = fraction
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                try await downloader.downloadAndInstall()
                progressTask.cancel()
            }

            downloadProgress = 0.9
            try await AssetInventory.reserve(locale: modelDef.locale)

            currentLocale = modelDef.locale
            loadedModelId = modelDef.id
            downloadProgress = 1.0
            modelState = .ready

            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            host?.notifyCapabilitiesChanged()
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    fileprivate func unloadModel() {
        if let locale = currentLocale {
            releaseTask = Task { await AssetInventory.release(reservedLocale: locale) }
        }
        currentLocale = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        host?.setUserDefault(nil, forKey: "loadedModel")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func restoreLoadedModel() async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = cachedModels.first(where: { $0.id == savedId }) else {
            return
        }
        await loadModel(modelDef)
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

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(SpeechAnalyzerSettingsView(plugin: self))
    }
}

// MARK: - Model Types

struct SpeechModelDef: Identifiable {
    let id: String
    let displayName: String
    let locale: Locale
}

@available(macOS 26, *)
enum SpeechModelState: Equatable {
    case notLoaded
    case downloading
    case ready
    case error(String)
}

// MARK: - Settings View

@available(macOS 26, *)
private struct SpeechAnalyzerSettingsView: View {
    let plugin: SpeechAnalyzerPlugin
    @State private var modelState: SpeechModelState = .notLoaded
    @State private var searchText = ""

    private var filteredModels: [SpeechModelDef] {
        if searchText.isEmpty {
            return plugin.cachedModels
        }
        return plugin.cachedModels.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple Speech")
                .font(.headline)

            Text("On-device speech recognition powered by Apple's Speech framework. System-managed models, streaming support.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if case .ready = modelState, let loadedId = plugin.loadedModelId {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    let modelName = plugin.cachedModels.first(where: { $0.id == loadedId })?.displayName ?? loadedId
                    Text("Active: \(modelName)")
                        .font(.callout)

                    Spacer()

                    Button("Unload") {
                        plugin.unloadModel()
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.1)))
            }

            if case .downloading = modelState {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading language model...")
                        .font(.callout)
                }
            }

            if case .error(let message) = modelState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            TextField("Search languages...", text: $searchText)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredModels) { modelDef in
                        languageRow(modelDef)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
        }
    }

    @ViewBuilder
    private func languageRow(_ modelDef: SpeechModelDef) -> some View {
        HStack {
            Text(modelDef.displayName)
                .font(.callout)

            Spacer()

            if plugin.loadedModelId == modelDef.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Select") {
                    Task {
                        await plugin.loadModel(modelDef)
                        modelState = plugin.modelState
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(modelState == .downloading)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }
}
