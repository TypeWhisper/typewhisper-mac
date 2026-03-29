import Foundation
import SwiftUI
@preconcurrency import AVFoundation
import Speech
import TypeWhisperPluginSDK
import os

// MARK: - Plugin Entry Point

@available(macOS 26, *)
@objc(SpeechAnalyzerPlugin)
final class SpeechAnalyzerPlugin: NSObject, TranscriptionEnginePlugin, PluginSettingsActivityReporting, @unchecked Sendable {
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

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel() } }

    func unloadModel(clearPersistence: Bool = true) {
        if let locale = currentLocale {
            releaseTask = Task { await AssetInventory.release(reservedLocale: locale) }
        }
        currentLocale = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func restoreLoadedModel() async {
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

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading language model",
                progress: downloadProgress
            )
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

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
    private let bundle = Bundle(for: SpeechAnalyzerPlugin.self)
    @State private var models: [SpeechModelDef] = []
    @State private var modelState: SpeechModelState = .notLoaded
    @State private var loadedModelId: String?
    @State private var searchText = ""
    @State private var isPolling = false

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var filteredModels: [SpeechModelDef] {
        if searchText.isEmpty {
            return models
        }
        return models.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device speech recognition via Apple's Speech framework with streaming support. Select a language model below - only one can be active at a time.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            if case .ready = modelState, let loadedId = loadedModelId {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    let modelName = models.first(where: { $0.id == loadedId })?.displayName ?? loadedId
                    Text("Active: \(modelName)", bundle: bundle)
                        .font(.callout)

                    Spacer()

                    Button(String(localized: "Unload", bundle: bundle)) {
                        plugin.unloadModel()
                        syncState()
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
                    Text("Downloading language model...", bundle: bundle)
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

            TextField(String(localized: "Search languages...", bundle: bundle), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if models.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading available languages...", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredModels) { modelDef in
                            languageRow(modelDef)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding()
        .task {
            if plugin.cachedModels.isEmpty {
                await plugin.populateModels()
            }
            syncState()
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
                loadedModelId = plugin.loadedModelId
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
    }

    private func syncState() {
        models = plugin.cachedModels
        modelState = plugin.modelState
        loadedModelId = plugin.loadedModelId
    }

    @ViewBuilder
    private func languageRow(_ modelDef: SpeechModelDef) -> some View {
        HStack {
            Text(modelDef.displayName)
                .font(.callout)

            Spacer()

            if loadedModelId == modelDef.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button(String(localized: "Select", bundle: bundle)) {
                    modelState = .downloading
                    isPolling = true
                    Task {
                        await plugin.loadModel(modelDef)
                        isPolling = false
                        syncState()
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
