import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

// MARK: - Plugin Entry Point

@objc(CohereLocalPlugin)
final class CohereLocalPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, HostModelLifecyclePolicyAwarePlugin, PluginSettingsWindowLayoutProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.cohere-transcribe"
    static let pluginName = "Cohere Transcribe (Local)"
    static let providerIdentifier = "cohere-transcribe"

    static var localizationBundle: Bundle {
#if SWIFT_PACKAGE
        .module
#else
        Bundle(for: CohereLocalPlugin.self)
#endif
    }

    static func localizedString(_ key: String, bundle: Bundle? = nil) -> String {
        let bundle = bundle ?? localizationBundle
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static let compactModel = CohereLocalModelDefinition(
        id: "cohere-transcribe-03-2026-q4_k",
        displayName: "Compact (Q4_K · Metal)",
        sizeDescription: "1.51 GB",
        ramRequirement: "8 GB+ Mac",
        detail: "Smallest download and memory footprint",
        fileName: "cohere-transcribe-q4_k.gguf",
        fileSize: 1_510_362_752,
        sha256: "2931fc0ac6d6708eef5389aadf1ebd5eec7b8e764bac385be585e910c0e7b410"
    )

    static let fastModel = CohereLocalModelDefinition(
        id: "cohere-transcribe-03-2026-q5_0",
        displayName: "Fast (Q5_0 · Recommended)",
        sizeDescription: "1.74 GB",
        ramRequirement: "8 GB+ Mac",
        detail: "Best tested balance of size, speed, and accuracy",
        fileName: "cohere-transcribe-q5_0.gguf",
        fileSize: 1_738_722_944,
        sha256: "a09696c5cc2ed5052bf290c4f2beb35abc69c0d6986842042d92bebb22c9184e"
    )

    static let q6Model = CohereLocalModelDefinition(
        id: "cohere-transcribe-03-2026-q6_k",
        displayName: "Higher precision (Q6_K · Metal)",
        sizeDescription: "1.98 GB",
        ramRequirement: "8 GB+ Mac",
        detail: "Intermediate quantization between recommended Q5_0 and Q8_0",
        fileName: "cohere-transcribe-q6_k.gguf",
        fileSize: 1_981_355_648,
        sha256: "0ad2634e0ba34efa38a47d4fd4cf34d7a2d738d8486d83b8d5a178f823109c52"
    )

    static let q8Model = CohereLocalModelDefinition(
        id: "cohere-transcribe-03-2026-q8_0",
        displayName: "Maximum precision (Q8_0 · Experimental)",
        sizeDescription: "2.42 GB",
        ramRequirement: "16 GB+ recommended",
        detail: "Largest quantization; no overall accuracy gain measured yet",
        fileName: "cohere-transcribe-q8_0.gguf",
        fileSize: 2_423_803_520,
        sha256: "c8620cb182a7c04e311e6c24e478b94f7ecd7f1b5230bf39fffa8daf94644f51"
    )
    static let models = [compactModel, fastModel, q6Model, q8Model]

    static let supportedLanguageCodes = [
        "en", "fr", "de", "es", "it", "pt", "nl",
        "pl", "el", "ar", "ja", "zh", "vi", "ko",
    ]

    private struct Runtime: Sendable {
        let server: CrispAsrServer
    }

    private struct State {
        var host: (any HostServices)?
        var selectedModelId: String?
        var loadedModelId: String?
        var runtime: Runtime?
        var startingServer: CrispAsrServer?
        var modelState: CohereLocalModelState = .notLoaded
        var loadGeneration = 0
        var huggingFaceToken: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    required override init() {
        super.init()
    }

    func activate(host: any HostServices) {
        let persistedSelection = host.userDefault(forKey: "selectedModel") as? String
        let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String
        let selectedModelId =
            Self.model(for: persistedSelection) != nil
            ? persistedSelection
            : Self.model(for: persistedLoadedModel)?.id ?? Self.fastModel.id
        let shouldRestore =
            host.shouldRestoreLoadedModelsPassively
            && Self.model(for: persistedLoadedModel) != nil
        let huggingFaceToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        state.withLock { state in
            state.host = host
            state.selectedModelId = selectedModelId
            state.huggingFaceToken = huggingFaceToken
        }

        if persistedSelection != selectedModelId {
            host.setUserDefault(selectedModelId, forKey: "selectedModel")
        }
        if shouldRestore {
            Task { [weak self] in
                await self?.restoreLoadedModel(allowDownloads: false)
            }
        }
    }

    func deactivate() {
        let servers = state.withLock { state -> (Runtime?, CrispAsrServer?) in
            let runtime = state.runtime
            let startingServer = state.startingServer
            state.loadGeneration += 1
            state.host = nil
            state.loadedModelId = nil
            state.runtime = nil
            state.startingServer = nil
            state.modelState = .notLoaded
            state.huggingFaceToken = nil
            return (runtime, startingServer)
        }
        servers.0?.server.stop()
        servers.1?.stop()
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { Self.providerIdentifier }
    var providerDisplayName: String { Self.localizedString(Self.pluginName) }

    var isConfigured: Bool {
        state.withLock {
            $0.runtime?.server.isRunning == true
                && $0.loadedModelId != nil
        }
    }

    var transcriptionModels: [PluginModelInfo] {
        availableModels
    }

    var availableModels: [PluginModelInfo] {
        let snapshot = state.withLock { state in
            (host: state.host, loadedModelId: state.loadedModelId)
        }
        return Self.models.map { model in
            let isDownloaded = snapshot.host.map {
                CohereLocalModelAssets(
                    pluginDataDirectory: $0.pluginDataDirectory,
                    model: model
                ).isInstalled
            } ?? false
            return PluginModelInfo(
                id: model.id,
                displayName: Self.localizedString(model.displayName),
                sizeDescription: Self.localizedString(model.sizeDescription),
                languageCount: Self.supportedLanguageCodes.count,
                downloaded: isDownloaded,
                loaded: snapshot.loadedModelId == model.id
            )
        }
    }

    var downloadedModels: [PluginModelInfo] {
        availableModels.filter { $0.downloaded == true }
    }

    var selectedModelId: String? {
        state.withLock { $0.selectedModelId }
    }

    func selectModel(_ modelId: String) {
        guard let model = Self.model(for: modelId) else { return }
        let context = state.withLock {
            state -> (
                host: (any HostServices)?,
                runtime: Runtime?,
                startingServer: CrispAsrServer?,
                shouldClearLoadedPersistence: Bool
            ) in
            let shouldClearLoadedPersistence = state.loadedModelId != modelId
            let shouldInvalidateLoad =
                state.selectedModelId != modelId
                || (state.loadedModelId != nil && state.loadedModelId != modelId)
            let runtime = shouldInvalidateLoad ? state.runtime : nil
            let startingServer = shouldInvalidateLoad ? state.startingServer : nil
            if shouldInvalidateLoad {
                state.loadGeneration += 1
                state.runtime = nil
                state.startingServer = nil
                state.loadedModelId = nil
                state.modelState = .notLoaded
            }
            state.selectedModelId = modelId
            return (
                state.host,
                runtime,
                startingServer,
                shouldClearLoadedPersistence
            )
        }

        context.runtime?.server.stop()
        context.startingServer?.stop()
        let isInstalled = context.host.map {
            CohereLocalModelAssets(
                pluginDataDirectory: $0.pluginDataDirectory,
                model: model
            ).isInstalled
        } == true
        let shouldRestore = isInstalled && state.withLock {
            $0.selectedModelId == modelId
                && $0.runtime == nil
                && $0.startingServer == nil
        }
        context.host?.setUserDefault(modelId, forKey: "selectedModel")
        if context.shouldClearLoadedPersistence {
            context.host?.setUserDefault(nil, forKey: "loadedModel")
        }
        context.host?.notifyCapabilitiesChanged()
        if shouldRestore {
            Task { [weak self] in
                await self?.loadModel(allowDownloads: false)
            }
        }
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { Self.supportedLanguageCodes }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt _: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            language: language,
            translate: translate,
            prompt: nil,
            onProgress: { _ in true }
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt _: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        if translate {
            throw CohereLocalPluginError.translationUnsupported
        }
        guard let cohereLanguage = Self.cohereLanguage(for: language) else {
            throw CohereLocalPluginError.explicitLanguageRequired(
                supportedLanguages: Self.supportedLanguageCodes
            )
        }
        guard let runtime = state.withLock({ $0.runtime }) else {
            throw CohereLocalPluginError.modelNotLoaded
        }

        guard !audio.samples.isEmpty, !Self.isDigitalSilence(audio.samples) else {
            return PluginTranscriptionResult(
                text: "",
                detectedLanguage: cohereLanguage
            )
        }

        return try await PluginLocalInferenceGate.shared.withLock {
            try Task.checkCancellation()
            let _ = onProgress(Self.localizedString("Running Cohere locally with Metal…"))
            let result = try await runtime.server.transcribe(
                audio: audio,
                language: cohereLanguage
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let _ = onProgress(text)
            return PluginTranscriptionResult(
                text: text,
                detectedLanguage: result.detectedLanguage ?? cohereLanguage,
                segments: result.segments
            )
        }
    }

    // MARK: - Model Management

    func loadModel(allowDownloads: Bool = true) async {
        guard let context = beginModelLoad() else { return }
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: context.host.pluginDataDirectory,
            model: context.model
        )
        var pendingServer: CrispAsrServer?

        do {
            if !assets.isInstalled {
                guard allowDownloads else {
                    throw CohereLocalPluginError.modelNotDownloaded
                }
                try await assets.download(bearerToken: context.huggingFaceToken) { [weak self] fraction in
                    self?.updateDownloadProgress(
                        fraction,
                        generation: context.generation
                    )
                }
            }

            try Task.checkCancellation()
            guard transitionToPreparing(generation: context.generation) else { return }

            let server = CrispAsrServer()
            pendingServer = server
            let didRegisterServer = state.withLock { state -> Bool in
                guard state.loadGeneration == context.generation else { return false }
                state.startingServer = server
                return true
            }
            guard didRegisterServer else { return }

            let runtime = try await PluginLocalInferenceGate.shared.withLock {
                try Task.checkCancellation()
                let isCurrent = state.withLock {
                    $0.loadGeneration == context.generation
                        && $0.startingServer === server
                }
                guard isCurrent else { throw CancellationError() }
                try await server.start(assets: assets)
                return Runtime(server: server)
            }

            let didInstall = state.withLock { state -> Bool in
                guard state.loadGeneration == context.generation,
                      state.startingServer === server else {
                    return false
                }
                state.startingServer = nil
                state.runtime = runtime
                state.loadedModelId = context.model.id
                state.selectedModelId = context.model.id
                state.modelState = .ready
                return true
            }
            guard didInstall else {
                server.stop()
                return
            }
            pendingServer = nil

            context.host.setUserDefault(context.model.id, forKey: "selectedModel")
            context.host.setUserDefault(context.model.id, forKey: "loadedModel")
            context.host.notifyCapabilitiesChanged()
        } catch is CancellationError {
            pendingServer?.stop()
            finishModelLoad(
                generation: context.generation,
                state: .notLoaded,
                host: context.host
            )
        } catch {
            pendingServer?.stop()
            finishModelLoad(
                generation: context.generation,
                state: .error(error.localizedDescription),
                host: context.host
            )
        }
    }

    func restoreLoadedModel(allowDownloads: Bool = false) async {
        let host = state.withLock { $0.host }
        let persistedModelId = host?.userDefault(forKey: "loadedModel") as? String
        guard host != nil,
              let loadedModelId = Self.model(for: persistedModelId)?.id else {
            return
        }
        state.withLock { $0.selectedModelId = loadedModelId }
        await loadModel(allowDownloads: allowDownloads)
    }

    func unloadModel(clearPersistence: Bool = true) {
        let context = state.withLock {
            state -> (
                host: (any HostServices)?,
                runtime: Runtime?,
                startingServer: CrispAsrServer?
            ) in
            let runtime = state.runtime
            let startingServer = state.startingServer
            state.loadGeneration += 1
            state.runtime = nil
            state.startingServer = nil
            state.loadedModelId = nil
            state.modelState = .notLoaded
            return (state.host, runtime, startingServer)
        }
        context.runtime?.server.stop()
        context.startingServer?.stop()
        if clearPersistence {
            context.host?.setUserDefault(nil, forKey: "loadedModel")
        }
        context.host?.notifyCapabilitiesChanged()
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard let model = Self.model(for: modelId) else { return }
        let host = state.withLock { $0.host }
        guard let host else { return }

        if state.withLock({ $0.loadedModelId == modelId }) {
            unloadModel(clearPersistence: true)
        }
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: model
        )
        try assets.deleteModelFiles(allModels: Self.models)
        let fallbackModel = Self.models.first { candidate in
            CohereLocalModelAssets(
                pluginDataDirectory: host.pluginDataDirectory,
                model: candidate
            ).isInstalled
        } ?? Self.fastModel

        state.withLock { state in
            if state.selectedModelId == modelId {
                state.selectedModelId = fallbackModel.id
                state.modelState = .notLoaded
            }
        }
        if selectedModelId == fallbackModel.id {
            host.setUserDefault(fallbackModel.id, forKey: "selectedModel")
        }
        host.notifyCapabilitiesChanged()
    }

    @objc func triggerAutoUnload() {
        unloadModel(clearPersistence: false)
    }

    @objc func triggerRestoreModel() {
        Task { [weak self] in
            await self?.restoreLoadedModel(allowDownloads: false)
        }
    }

    @objc(triggerRestoreModelForModel:)
    func triggerRestoreModel(forModel modelId: NSString?) {
        guard modelId == nil || modelId.map(String.init).flatMap(Self.model(for:)) != nil else {
            return
        }
        if let modelId = modelId.map(String.init) {
            selectModel(modelId)
        }
        Task { [weak self] in
            await self?.loadModel(allowDownloads: true)
        }
    }

    private func beginModelLoad() -> (
        host: any HostServices,
        model: CohereLocalModelDefinition,
        generation: Int,
        huggingFaceToken: String?
    )? {
        let snapshot = state.withLock {
            (
                host: $0.host,
                selectedModelId: $0.selectedModelId,
                generation: $0.loadGeneration
            )
        }
        guard let host = snapshot.host,
              let model = Self.model(for: snapshot.selectedModelId) else {
            return nil
        }
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: model
        )
        let isInstalled = assets.isInstalled

        return state.withLock { state -> (
            host: any HostServices,
            model: CohereLocalModelDefinition,
            generation: Int,
            huggingFaceToken: String?
        )? in
            guard state.host != nil,
                  state.selectedModelId == model.id,
                  state.loadGeneration == snapshot.generation else {
                return nil
            }
            guard state.runtime == nil else {
                state.modelState = .ready
                return nil
            }
            switch state.modelState {
            case .downloading, .preparing:
                return nil
            case .notLoaded, .ready, .error:
                break
            }

            state.loadGeneration += 1
            state.modelState = isInstalled ? .preparing : .downloading(progress: 0)
            return (host, model, state.loadGeneration, state.huggingFaceToken)
        }
    }

    private func updateDownloadProgress(_ fraction: Double, generation: Int) {
        state.withLock { state in
            guard state.loadGeneration == generation else { return }
            state.modelState = .downloading(progress: min(max(fraction, 0), 1))
        }
    }

    private func transitionToPreparing(generation: Int) -> Bool {
        state.withLock { state in
            guard state.loadGeneration == generation else { return false }
            state.modelState = .preparing
            return true
        }
    }

    private func finishModelLoad(
        generation: Int,
        state newState: CohereLocalModelState,
        host: any HostServices
    ) {
        let didFinish = state.withLock { state -> Bool in
            guard state.loadGeneration == generation else { return false }
            state.runtime = nil
            state.startingServer = nil
            state.loadedModelId = nil
            state.modelState = newState
            return true
        }
        if didFinish {
            host.notifyCapabilitiesChanged()
        }
    }

    // MARK: - Settings

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading(let progress):
            return PluginSettingsActivity(
                message: Self.localizedString("Downloading Cohere model"),
                progress: progress
            )
        case .preparing:
            return PluginSettingsActivity(
                message: Self.localizedString("Starting and warming up Cohere with Metal")
            )
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var modelState: CohereLocalModelState {
        state.withLock { $0.modelState }
    }

    var huggingFaceToken: String? {
        state.withLock { $0.huggingFaceToken }
    }

    func setHuggingFaceToken(_ token: String) {
        let host = state.withLock { $0.host }
        let savedToken = PluginHuggingFaceTokenHelper.saveToken(token, to: host)
        state.withLock { $0.huggingFaceToken = savedToken }
    }

    func clearHuggingFaceToken() {
        let host = state.withLock { $0.host }
        PluginHuggingFaceTokenHelper.clearToken(from: host)
        state.withLock { $0.huggingFaceToken = nil }
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
            = PluginHTTPClient.data
    ) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(
            token,
            dataFetcher: dataFetcher
        )
    }

    var isModelDownloaded: Bool {
        let snapshot = state.withLock {
            (host: $0.host, selectedModelId: $0.selectedModelId)
        }
        guard let host = snapshot.host,
              let model = Self.model(for: snapshot.selectedModelId) else {
            return false
        }
        return CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: model
        ).isInstalled
    }

    var selectedModelDefinition: CohereLocalModelDefinition {
        state.withLock { Self.model(for: $0.selectedModelId) ?? Self.fastModel }
    }

    var canDismissSettingsAfterSetup: Bool {
        if case .ready = modelState {
            return true
        }
        return false
    }

    var settingsViewManagesScrolling: Bool { true }
    var preferredSettingsWindowSize: CGSize? { CGSize(width: 620, height: 650) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 520, height: 560) }

    @MainActor
    var settingsView: AnyView? {
        AnyView(CohereLocalSettingsView(plugin: self))
    }

    // MARK: - Language and VAD Helpers

    static func normalizedLanguageCode(for language: String?) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty, normalized != "auto", normalized != "und" else {
            return nil
        }

        let baseCode = normalized.split(separator: "-", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        let canonicalCode = baseCode == "cmn" ? "zh" : baseCode
        guard let canonicalCode, supportedLanguageCodes.contains(canonicalCode) else {
            return nil
        }
        return canonicalCode
    }

    static func cohereLanguage(for language: String?) -> String? {
        normalizedLanguageCode(for: language)
    }

    static func model(for id: String?) -> CohereLocalModelDefinition? {
        models.first { $0.id == id }
    }

    static func isDigitalSilence(_ samples: [Float]) -> Bool {
        samples.allSatisfy { abs($0) <= 0.000_001 }
    }

}

// MARK: - Model Assets

struct CohereLocalModelDefinition: Sendable, Equatable {
    let id: String
    let displayName: String
    let sizeDescription: String
    let ramRequirement: String
    let detail: String
    let fileName: String
    let fileSize: Int64
    let sha256: String

    var localizationKeys: [String] {
        [displayName, sizeDescription, ramRequirement, detail]
    }
}

enum CohereLocalModelState: Sendable, Equatable {
    case notLoaded
    case downloading(progress: Double)
    case preparing
    case ready
    case error(String)
}

enum CohereLocalPluginError: LocalizedError, Sendable {
    case explicitLanguageRequired(supportedLanguages: [String])
    case translationUnsupported
    case modelNotDownloaded
    case modelNotLoaded
    case invalidRepositoryIdentifier
    case incompleteModelDownload
    case runtimeDownloadFailed
    case invalidRuntimeArchive
    case runtimeExtractionFailed(String)
    case assetVerificationFailed(String)
    case invalidLocalServerURL
    case localPortReservationFailed
    case runtimeExited(String)
    case runtimeStartupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .explicitLanguageRequired(let supportedLanguages):
            let message = CohereLocalPlugin.localizedString(
                "Cohere Transcribe requires an explicitly selected supported language. Automatic language detection is not available. Supported languages:"
            )
            return "\(message) \(supportedLanguages.joined(separator: ", "))."
        case .translationUnsupported:
            return CohereLocalPlugin.localizedString(
                "Cohere Transcribe does not support translation."
            )
        case .modelNotDownloaded:
            return CohereLocalPlugin.localizedString(
                "The Cohere Transcribe model is not downloaded."
            )
        case .modelNotLoaded:
            return CohereLocalPlugin.localizedString(
                "The Cohere Transcribe model is not loaded. Open the plugin settings and load it first."
            )
        case .invalidRepositoryIdentifier:
            return CohereLocalPlugin.localizedString(
                "The pinned Cohere model repository identifier is invalid."
            )
        case .incompleteModelDownload:
            return CohereLocalPlugin.localizedString(
                "The Cohere model download completed without all required model files."
            )
        case .runtimeDownloadFailed:
            return CohereLocalPlugin.localizedString(
                "The CrispASR runtime download failed."
            )
        case .invalidRuntimeArchive:
            return CohereLocalPlugin.localizedString(
                "The verified CrispASR runtime archive is incomplete."
            )
        case .runtimeExtractionFailed(let message):
            let description = CohereLocalPlugin.localizedString(
                "The CrispASR runtime could not be extracted."
            )
            return "\(description) \(message)"
        case .assetVerificationFailed(let fileName):
            let description = CohereLocalPlugin.localizedString(
                "Cohere asset verification failed for:"
            )
            return "\(description) \(fileName)."
        case .invalidLocalServerURL:
            return CohereLocalPlugin.localizedString(
                "The local CrispASR server URL is invalid."
            )
        case .localPortReservationFailed:
            return CohereLocalPlugin.localizedString(
                "TypeWhisper could not reserve a local port for Cohere Transcribe."
            )
        case .runtimeExited(let output):
            let description = CohereLocalPlugin.localizedString(
                "CrispASR exited while starting."
            )
            return "\(description)\(output.isEmpty ? "" : "\n\(output)")"
        case .runtimeStartupTimedOut(let output):
            let description = CohereLocalPlugin.localizedString(
                "CrispASR did not become ready within five minutes."
            )
            return "\(description)\(output.isEmpty ? "" : "\n\(output)")"
        }
    }
}

// MARK: - Settings View

@MainActor
private struct CohereLocalSettingsView: View {
    let plugin: CohereLocalPlugin

    private let bundle = CohereLocalPlugin.localizationBundle
    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let cohereModelURL = URL(
        string: "https://huggingface.co/\(CohereLocalModelAssets.modelRepositoryId)"
    )!
    private let crispAsrURL = URL(
        string: "https://github.com/CrispStrobe/CrispASR/tree/v\(CohereLocalModelAssets.crispAsrVersion)"
    )!
    private let vadModelURL = URL(
        string: "https://huggingface.co/ggml-org/whisper-vad"
    )!

    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginSettingsClose) private var closeSettings
    @State private var modelState: CohereLocalModelState = .notLoaded
    @State private var selectedModelId = CohereLocalPlugin.fastModel.id
    @State private var isDownloaded = false
    @State private var showDeleteConfirmation = false
    @State private var huggingFaceTokenInput = ""
    @State private var showHuggingFaceToken = false
    @State private var isValidatingHuggingFaceToken = false
    @State private var huggingFaceTokenValidationResult: Bool?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    huggingFaceTokenSection
                    modelCard
                    capabilityNotes
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: bundle)) {
                    if let closeSettings {
                        closeSettings()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onAppear {
            refresh()
            huggingFaceTokenInput = plugin.huggingFaceToken ?? ""
        }
        .onReceive(pollTimer) { _ in refresh() }
        .onChange(of: huggingFaceTokenInput) { _, newValue in
            let normalized = PluginHuggingFaceTokenHelper.normalizedToken(newValue)
            if normalized != plugin.huggingFaceToken {
                huggingFaceTokenValidationResult = nil
            }
        }
        .alert(
            String(localized: "Remove downloaded model?", bundle: bundle),
            isPresented: $showDeleteConfirmation
        ) {
            Button(String(localized: "Cancel", bundle: bundle), role: .cancel) {}
            Button(String(localized: "Remove Model", bundle: bundle), role: .destructive) {
                Task {
                    try? await plugin.deleteDownloadedModel(selectedModelId)
                    refresh()
                }
            }
        } message: {
            Text(
                "This removes the selected Cohere model. Shared runtime files remain while another variant is installed.",
                bundle: bundle
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Cohere Transcribe (Local)", bundle: bundle)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("LOCAL · BATCH", bundle: bundle)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Text(
                "A private on-device GGUF and Metal provider for Cohere Transcribe 03-2026. Audio stays on this Mac.",
                bundle: bundle
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var modelCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    String(localized: "Model", bundle: bundle),
                    selection: $selectedModelId
                ) {
                    ForEach(CohereLocalPlugin.models, id: \.id) { model in
                        Text(CohereLocalPlugin.localizedString(model.displayName, bundle: bundle))
                            .tag(model.id)
                    }
                }
                .onChange(of: selectedModelId) { _, newValue in
                    guard newValue != plugin.selectedModelId else { return }
                    plugin.selectModel(newValue)
                    refresh()
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CohereLocalPlugin.localizedString(
                            selectedModel.displayName,
                            bundle: bundle
                        ))
                            .font(.headline)
                        Text(
                            "\(CohereLocalPlugin.localizedString(selectedModel.sizeDescription, bundle: bundle)) · \(CohereLocalPlugin.localizedString(selectedModel.ramRequirement, bundle: bundle))"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(CohereLocalPlugin.localizedString(
                            selectedModel.detail,
                            bundle: bundle
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusLabel
                }

                if case .downloading(let progress) = modelState {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if case .preparing = modelState {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Starting CrispASR with Metal and warming up the model. Dictation is ready when this finishes.",
                            bundle: bundle
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else if case .error(let message) = modelState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    primaryModelButton
                    if isDownloaded, !isBusy {
                        Button(String(localized: "Remove Model", bundle: bundle), role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private var huggingFaceTokenSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hugging Face Token", bundle: bundle)
                    .font(.headline)

                Text(
                    "Optional. Increases download rate limits and may speed up the model download. The token is stored securely in Keychain.",
                    bundle: bundle
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    if showHuggingFaceToken {
                        TextField("hf_...", text: $huggingFaceTokenInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("hf_...", text: $huggingFaceTokenInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showHuggingFaceToken.toggle()
                    } label: {
                        Image(systemName: showHuggingFaceToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.huggingFaceToken != nil {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            huggingFaceTokenInput = ""
                            huggingFaceTokenValidationResult = nil
                            plugin.clearHuggingFaceToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSaveHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        PluginHuggingFaceTokenHelper.normalizedToken(huggingFaceTokenInput) == nil
                            || isValidatingHuggingFaceToken
                    )
                }

                if isValidatingHuggingFaceToken {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating token…", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let huggingFaceTokenValidationResult {
                    Label(
                        huggingFaceTokenValidationResult
                            ? String(localized: "Valid Hugging Face Token", bundle: bundle)
                            : String(localized: "Invalid Hugging Face Token", bundle: bundle),
                        systemImage: huggingFaceTokenValidationResult
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(huggingFaceTokenValidationResult ? .green : .red)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch modelState {
        case .ready:
            Label(String(localized: "Ready", bundle: bundle), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading:
            Label(String(localized: "Downloading", bundle: bundle), systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .preparing:
            Label(String(localized: "Preparing", bundle: bundle), systemImage: "gearshape.2")
                .foregroundStyle(.secondary)
        case .error:
            Label(String(localized: "Error", bundle: bundle), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .notLoaded:
            Label(
                String(localized: isDownloaded ? "Downloaded" : "Not Downloaded", bundle: bundle),
                systemImage: isDownloaded ? "internaldrive" : "icloud.and.arrow.down"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var primaryModelButton: some View {
        switch modelState {
        case .ready:
            Button(String(localized: "Unload", bundle: bundle)) {
                plugin.unloadModel()
                refresh()
            }
            .buttonStyle(.bordered)
        case .downloading, .preparing:
            Button(String(localized: "Working…", bundle: bundle)) {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .notLoaded, .error:
            Button(
                String(localized: isDownloaded ? "Load" : "Download & Load", bundle: bundle)
            ) {
                Task {
                    await plugin.loadModel()
                    refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var capabilityNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capabilities and limits", bundle: bundle)
                .font(.headline)

            capabilityRow(
                icon: "globe",
                text: String(
                    localized: "14 languages with explicit selection: English, French, German, Spanish, Italian, Portuguese, Dutch, Polish, Greek, Arabic, Japanese, Chinese, Vietnamese, and Korean.",
                    bundle: bundle
                )
            )
            capabilityRow(
                icon: "waveform.path",
                text: String(
                    localized: "Voice activity detection runs before every transcription to suppress silence and low-noise hallucinations.",
                    bundle: bundle
                )
            )
            capabilityRow(
                icon: "exclamationmark.circle",
                text: String(
                    localized: "No automatic language detection, streaming, timestamps, diarization, translation, or dictionary boosting.",
                    bundle: bundle
                )
            )
            capabilityRow(
                icon: "memorychip",
                text: String(
                    localized: "Choose Compact Q4_K for the smallest download, Fast Q5_0 for the recommended default, Q6_K for higher numeric precision, or experimental Q8_0 for maximum numeric precision. Only the selected model is loaded.",
                    bundle: bundle
                )
            )
            capabilityRow(
                icon: "hourglass",
                text: String(
                    localized: "The model stays resident while loaded. Metal is warmed up before the provider becomes ready, keeping the first transcription responsive.",
                    bundle: bundle
                )
            )

            Divider()

            Text(
                "Model weights are downloaded from a pinned Apache-2.0 GGUF revision. CrispASR and the VAD model are MIT-licensed.",
                bundle: bundle
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Link(
                    String(localized: "Cohere model license", bundle: bundle),
                    destination: cohereModelURL
                )
                Link(
                    String(localized: "CrispASR license and notices", bundle: bundle),
                    destination: crispAsrURL
                )
                Link(
                    String(localized: "VAD model license", bundle: bundle),
                    destination: vadModelURL
                )
            }
            .font(.caption)
        }
    }

    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isBusy: Bool {
        switch modelState {
        case .downloading, .preparing:
            return true
        case .notLoaded, .ready, .error:
            return false
        }
    }

    private var selectedModel: CohereLocalModelDefinition {
        CohereLocalPlugin.model(for: selectedModelId) ?? CohereLocalPlugin.fastModel
    }

    private func refresh() {
        modelState = plugin.modelState
        selectedModelId = plugin.selectedModelId ?? CohereLocalPlugin.fastModel.id
        isDownloaded = plugin.isModelDownloaded
    }

    private func validateAndSaveHuggingFaceToken() {
        guard let token = PluginHuggingFaceTokenHelper.normalizedToken(
            huggingFaceTokenInput
        ) else {
            huggingFaceTokenValidationResult = false
            return
        }

        isValidatingHuggingFaceToken = true
        huggingFaceTokenValidationResult = nil
        Task {
            let isValid = await plugin.validateHuggingFaceToken(token)
            isValidatingHuggingFaceToken = false
            huggingFaceTokenValidationResult = isValid
            if isValid {
                plugin.setHuggingFaceToken(token)
                huggingFaceTokenInput = token
            }
        }
    }
}
