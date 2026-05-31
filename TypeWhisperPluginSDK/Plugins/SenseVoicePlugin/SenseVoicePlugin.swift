import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

enum SenseVoiceDefaultsKey {
    static let selectedModel = "selectedModel"
    static let loadedModel = "loadedModel"
    static let acceptedModelLicenseId = "acceptedModelLicenseId"
    static let acceptedModelLicenseRevision = "acceptedModelLicenseRevision"
    static let acceptedModelLicenseAt = "acceptedModelLicenseAt"
}

enum SenseVoiceModelState: Equatable, Sendable {
    case notDownloaded
    case downloading
    case ready
    case error(String)
}

protocol SenseVoiceRecognizing: AnyObject, Sendable {
    func transcribe(samples: [Float], sampleRate: Int) throws -> String
}

typealias SenseVoiceRecognizerFactory = @Sendable (URL, String) throws -> any SenseVoiceRecognizing

@objc(SenseVoicePlugin)
final class SenseVoicePlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.sensevoice"
    static let pluginName = "SenseVoice (Experimental)"

    private let logger = Logger(subsystem: "com.typewhisper.plugin.sensevoice", category: "Transcription")
    private var host: HostServices?
    private var downloadProgress = 0.0
    private(set) var modelState: SenseVoiceModelState = .notDownloaded
    private let recognizerLock = NSLock()
    private var recognizerLanguage: String?
    private var recognizer: (any SenseVoiceRecognizing)?
    private var recognizerFactory: SenseVoiceRecognizerFactory = { modelDirectory, language in
        try SenseVoiceONNXRecognizer(modelDirectory: modelDirectory, language: language)
    }

    required override init() {
        super.init()
    }

    init(recognizerFactory: @escaping SenseVoiceRecognizerFactory) {
        self.recognizerFactory = recognizerFactory
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        if host.userDefault(forKey: SenseVoiceDefaultsKey.selectedModel) as? String == nil {
            host.setUserDefault(SenseVoiceModelAssetManager.modelId, forKey: SenseVoiceDefaultsKey.selectedModel)
        }
        modelState = modelAssetManager.hasDownloadedModel() ? .ready : .notDownloaded
        if modelAssetManager.hasDownloadedModel() {
            host.setUserDefault(SenseVoiceModelAssetManager.modelId, forKey: SenseVoiceDefaultsKey.loadedModel)
        }
    }

    func deactivate() {
        clearRecognizerCache()
        host = nil
        downloadProgress = 0
        modelState = .notDownloaded
    }

    var providerId: String { "sensevoice" }
    var providerDisplayName: String { "SenseVoice (Experimental)" }
    var isConfigured: Bool { modelAssetManager.hasDownloadedModel() }

    var transcriptionModels: [PluginModelInfo] { availableModels }

    var availableModels: [PluginModelInfo] {
        [
            PluginModelInfo(
                id: SenseVoiceModelAssetManager.modelId,
                displayName: SenseVoiceModelAssetManager.displayName,
                sizeDescription: SenseVoiceModelAssetManager.sizeDescription,
                languageCount: supportedLanguages.count,
                downloaded: modelAssetManager.hasDownloadedModel(),
                loaded: modelState == .ready
            )
        ]
    }

    var downloadedModels: [PluginModelInfo] {
        guard modelAssetManager.hasDownloadedModel() else { return [] }
        return availableModels
    }

    var selectedModelId: String? {
        (host?.userDefault(forKey: SenseVoiceDefaultsKey.selectedModel) as? String) ?? SenseVoiceModelAssetManager.modelId
    }

    func selectModel(_ modelId: String) {
        guard modelId == SenseVoiceModelAssetManager.modelId else { return }
        host?.setUserDefault(modelId, forKey: SenseVoiceDefaultsKey.selectedModel)
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { SenseVoiceLanguageResolver.supportedLanguageCodes }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notDownloaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(message: "Downloading SenseVoice model", progress: downloadProgress)
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(SenseVoiceSettingsView(plugin: self))
    }

    var hasAcceptedCurrentModelLicense: Bool {
        guard let host else { return false }
        return host.userDefault(forKey: SenseVoiceDefaultsKey.acceptedModelLicenseId) as? String == SenseVoiceModelLicense.id
            && host.userDefault(forKey: SenseVoiceDefaultsKey.acceptedModelLicenseRevision) as? String == SenseVoiceModelLicense.revision
    }

    var canDownloadModel: Bool {
        hasAcceptedCurrentModelLicense
    }

    var modelDownloadProgress: Double {
        downloadProgress
    }

    func acceptCurrentModelLicense(now: Date = Date()) {
        host?.setUserDefault(SenseVoiceModelLicense.id, forKey: SenseVoiceDefaultsKey.acceptedModelLicenseId)
        host?.setUserDefault(SenseVoiceModelLicense.revision, forKey: SenseVoiceDefaultsKey.acceptedModelLicenseRevision)
        host?.setUserDefault(Self.isoDateString(from: now), forKey: SenseVoiceDefaultsKey.acceptedModelLicenseAt)
        host?.notifyCapabilitiesChanged()
    }

    func downloadModel() async {
        guard canDownloadModel else {
            modelState = .error(SenseVoicePluginError.licenseNotAccepted.localizedDescription)
            host?.notifyCapabilitiesChanged()
            return
        }

        downloadProgress = 0
        modelState = .downloading
        host?.notifyCapabilitiesChanged()

        do {
            try await modelAssetManager.download(licenseAccepted: true) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.host?.notifyCapabilitiesChanged()
                }
            }
            clearRecognizerCache()
            downloadProgress = 1
            modelState = .ready
            host?.setUserDefault(SenseVoiceModelAssetManager.modelId, forKey: SenseVoiceDefaultsKey.selectedModel)
            host?.setUserDefault(SenseVoiceModelAssetManager.modelId, forKey: SenseVoiceDefaultsKey.loadedModel)
            host?.notifyCapabilitiesChanged()
        } catch {
            logger.error("SenseVoice model download failed: \(error.localizedDescription)")
            downloadProgress = 0
            modelState = .error(error.localizedDescription)
            host?.notifyCapabilitiesChanged()
        }
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard modelId == SenseVoiceModelAssetManager.modelId else { return }
        try deleteCachedModel()
    }

    func deleteCachedModel() throws {
        clearRecognizerCache()
        try modelAssetManager.deleteModelFiles()
        downloadProgress = 0
        modelState = .notDownloaded
        host?.setUserDefault(nil, forKey: SenseVoiceDefaultsKey.loadedModel)
        host?.notifyCapabilitiesChanged()
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard !translate else { throw SenseVoicePluginError.unsupportedTranslation }
        guard modelAssetManager.hasDownloadedModel() else { throw SenseVoicePluginError.notConfigured }

        let runtimeLanguage = SenseVoiceLanguageResolver.runtimeLanguage(for: language)
        let modelDirectory = modelAssetManager.modelDirectory
        let text = try await Task.detached(priority: .userInitiated) { [self] in
            try recognizer(for: runtimeLanguage, modelDirectory: modelDirectory)
                .transcribe(samples: audio.samples, sampleRate: 16_000)
        }.value

        return PluginTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: runtimeLanguage == "auto" ? nil : runtimeLanguage,
            segments: []
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let result = try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
        _ = onProgress(result.text)
        return result
    }

    fileprivate var modelAssetManager: SenseVoiceModelAssetManager {
        SenseVoiceModelAssetManager(
            rootDirectory: host?.pluginDataDirectory
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("SenseVoicePlugin", isDirectory: true)
        )
    }

    private func recognizer(for language: String, modelDirectory: URL) throws -> any SenseVoiceRecognizing {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }

        if let recognizer, recognizerLanguage == language {
            return recognizer
        }

        let recognizer = try recognizerFactory(modelDirectory, language)
        self.recognizer = recognizer
        recognizerLanguage = language
        return recognizer
    }

    private func clearRecognizerCache() {
        recognizerLock.lock()
        recognizer = nil
        recognizerLanguage = nil
        recognizerLock.unlock()
    }

    private static func isoDateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct SenseVoiceSettingsView: View {
    let plugin: SenseVoicePlugin

    @State private var acceptedLicense = false
    @State private var modelState: SenseVoiceModelState = .notDownloaded
    @State private var progress = 0.0
    @State private var isDownloading = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SenseVoice (Experimental)")
                .font(.headline)

            Text("Local speech recognition through SenseVoice Small and Sherpa-ONNX. This experimental engine is limited to Chinese, English, Japanese, Korean, and Cantonese.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            licenseSection

            Divider()

            modelSection
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            refreshFromPlugin()
        }
        .onReceive(pollTimer) { _ in
            refreshTransientState()
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model License")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("SenseVoiceSmall model assets are downloaded only after you accept the model license. Review the license before downloading.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("Open SenseVoiceSmall model license", destination: SenseVoiceModelLicense.url)
                .font(.caption)

            Toggle(isOn: $acceptedLicense) {
                Text("I have read and accept the SenseVoiceSmall model license terms")
            }
            .onChange(of: acceptedLicense) { _, newValue in
                if newValue {
                    plugin.acceptCurrentModelLicense()
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("\(SenseVoiceModelAssetManager.displayName) - \(SenseVoiceModelAssetManager.sizeDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch modelState {
            case .ready:
                HStack {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Delete cached model") {
                        try? plugin.deleteCachedModel()
                        refreshFromPlugin()
                    }
                    .controlSize(.small)
                }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 160)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                downloadButton
            case .notDownloaded:
                downloadButton
            }
        }
    }

    private var downloadButton: some View {
        Button {
            isDownloading = true
            Task {
                await plugin.downloadModel()
                await MainActor.run {
                    isDownloading = false
                    refreshFromPlugin()
                }
            }
        } label: {
            Label("Download & Load", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!acceptedLicense || isDownloading || modelState == .downloading)
    }

    private func refreshFromPlugin() {
        acceptedLicense = plugin.hasAcceptedCurrentModelLicense
        modelState = plugin.modelState
        progress = plugin.modelDownloadProgress
    }

    private func refreshTransientState() {
        modelState = plugin.modelState
        progress = plugin.modelDownloadProgress
    }
}
