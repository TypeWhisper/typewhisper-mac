import Combine
import Foundation
import TypeWhisperPluginSDK

struct DictationRecoveryFallbackConfiguration: Equatable, Sendable {
    let engineId: String
    let modelId: String?
}

@MainActor
final class DictationRecoveryViewModel: ObservableObject {
    typealias AudioSamplesLoader = @MainActor (URL) async throws -> [Float]
    typealias TranscriptionRunner = @MainActor (
        [Float],
        LanguageSelection,
        TranscriptionTask,
        String?,
        String?
    ) async throws -> TranscriptionResult
    typealias EngineReadinessChecker = @MainActor (String?) -> Bool

    nonisolated(unsafe) static var _shared: DictationRecoveryViewModel?
    static var shared: DictationRecoveryViewModel {
        guard let instance = _shared else {
            fatalError("DictationRecoveryViewModel not initialized")
        }
        return instance
    }

    enum RecoveryState: Equatable {
        case idle
        case loading
        case transcribing
        case error
    }

    struct RecoveryItem: Identifiable {
        let url: URL
        var state: RecoveryState = .idle
        var errorMessage: String?

        var id: String { url.path }
        var fileName: String { url.lastPathComponent }

        var isProcessing: Bool {
            state == .loading || state == .transcribing
        }
    }

    @Published private(set) var recoveries: [RecoveryItem]
    @Published var selectedRecoveryID: RecoveryItem.ID?
    @Published private(set) var lastSavedRecoveryFileName: String?
    @Published private(set) var lastSavedHistoryRecordID: UUID?
    @Published var languageSelection: LanguageSelection = .auto {
        didSet {
            defaults.set(
                languageSelection.storedValue(nilBehavior: .auto),
                forKey: UserDefaultsKeys.dictationRecoveryLanguage
            )
        }
    }
    @Published var selectedTask: TranscriptionTask = .transcribe
    @Published var selectedEngine: String? {
        didSet {
            defaults.set(selectedEngine, forKey: UserDefaultsKeys.dictationRecoveryEngine)
            guard isInitialized, oldValue != selectedEngine else { return }
            selectedModel = nil
            normalizeLanguageSelectionForResolvedEngine()
        }
    }
    @Published var selectedModel: String? {
        didSet { defaults.set(selectedModel, forKey: UserDefaultsKeys.dictationRecoveryModel) }
    }
    @Published var automaticFallbackEnabled: Bool {
        didSet {
            defaults.set(automaticFallbackEnabled, forKey: UserDefaultsKeys.dictationRecoveryAutomaticFallbackEnabled)
        }
    }

    private let audioRecordingService: AudioRecordingService
    private let modelManager: ModelManagerService
    private let historyService: HistoryService
    private let usageStatisticsRecorder: UsageStatisticsRecording?
    private let licenseService: LicenseService?
    private let audioSamplesLoader: AudioSamplesLoader
    private let transcriptionRunner: TranscriptionRunner
    private let engineReadinessChecker: EngineReadinessChecker?
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var isInitialized = false

    init(
        audioRecordingService: AudioRecordingService,
        modelManager: ModelManagerService,
        historyService: HistoryService,
        audioFileService: AudioFileService,
        usageStatisticsRecorder: UsageStatisticsRecording? = nil,
        licenseService: LicenseService? = nil,
        defaults: UserDefaults = .standard,
        audioSamplesLoader: AudioSamplesLoader? = nil,
        transcriptionRunner: TranscriptionRunner? = nil,
        engineReadinessChecker: EngineReadinessChecker? = nil
    ) {
        self.audioRecordingService = audioRecordingService
        self.modelManager = modelManager
        self.historyService = historyService
        self.usageStatisticsRecorder = usageStatisticsRecorder
        self.licenseService = licenseService
        self.defaults = defaults
        self.audioSamplesLoader = audioSamplesLoader ?? { [audioFileService] url in
            try await audioFileService.loadAudioSamples(from: url)
        }
        self.transcriptionRunner = transcriptionRunner ?? { [modelManager] samples, languageSelection, task, engineOverrideId, cloudModelOverride in
            try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride
            )
        }
        self.engineReadinessChecker = engineReadinessChecker
        let initialRecoveryURLs = audioRecordingService.recoveryRecordingURLs
        self.recoveries = initialRecoveryURLs.map { RecoveryItem(url: $0) }
        self.selectedRecoveryID = initialRecoveryURLs.first?.path
        self.languageSelection = LanguageSelection(
            storedValue: defaults.string(forKey: UserDefaultsKeys.dictationRecoveryLanguage),
            nilBehavior: .auto
        )
        self.selectedEngine = defaults.string(forKey: UserDefaultsKeys.dictationRecoveryEngine)
        self.selectedModel = defaults.string(forKey: UserDefaultsKeys.dictationRecoveryModel)
        self.automaticFallbackEnabled = defaults.bool(forKey: UserDefaultsKeys.dictationRecoveryAutomaticFallbackEnabled)
        self.isInitialized = true

        audioRecordingService.$recoverableRecordingURLs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] urls in
                self?.updateRecoveryURLs(urls)
            }
            .store(in: &cancellables)

        licenseService?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        reconcileSelectionWithAvailablePlugins()
    }

    var hasRecovery: Bool {
        !recoveries.isEmpty
    }

    var hasRecoveryContent: Bool {
        hasRecovery || lastSavedHistoryRecordID != nil
    }

    var selectedRecovery: RecoveryItem? {
        if let selectedRecoveryID,
           let selectedRecovery = recoveries.first(where: { $0.id == selectedRecoveryID }) {
            return selectedRecovery
        }
        return recoveries.first
    }

    var recoveryURL: URL? {
        selectedRecovery?.url
    }

    var state: RecoveryState {
        selectedRecovery?.state ?? .idle
    }

    var errorMessage: String? {
        selectedRecovery?.errorMessage
    }

    var fileName: String {
        selectedRecovery?.fileName ?? localizedAppText("No recording", de: "Keine Aufnahme")
    }

    var isProcessing: Bool {
        recoveries.contains { $0.isProcessing }
    }

    var canTranscribe: Bool {
        selectedRecovery != nil && selectedEngineIsReady && !isProcessing
    }

    var supportsTranslation: Bool {
        resolvedEngine?.supportsTranslation ?? false
    }

    var availableEngines: [TranscriptionEnginePlugin] {
        guard let pluginManager = PluginManager.shared else { return [] }
        return pluginManager.transcriptionEngines
    }

    var resolvedEngine: TranscriptionEnginePlugin? {
        let engineId = selectedEngine ?? modelManager.selectedProviderId
        guard let engineId else { return nil }
        guard let pluginManager = PluginManager.shared else { return nil }
        return pluginManager.transcriptionEngine(for: engineId)
    }

    var selectedEngineSupportedLanguages: [String] {
        resolvedEngine?.supportedLanguages.sorted() ?? []
    }

    var canUseAutomaticFallback: Bool {
        licenseService?.canUseProTranscriptionFallback ?? false
    }

    var automaticFallbackUnavailableMessage: String? {
        guard !canUseAutomaticFallback else { return nil }
        return localizedAppText(
            "Automatic fallback requires a commercial license or active supporter status.",
            de: "Automatischer Fallback benötigt eine kommerzielle Lizenz oder aktiven Supporter-Status."
        )
    }

    func observePluginManager() {
        guard let pluginManager = PluginManager.shared else { return }
        pluginManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileSelectionWithAvailablePlugins()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func canUseForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canUseForTranscription(engine)
    }

    func automaticFallbackConfiguration(
        excluding primaryEngineId: String?,
        task: TranscriptionTask
    ) -> DictationRecoveryFallbackConfiguration? {
        guard automaticFallbackEnabled, canUseAutomaticFallback else { return nil }
        guard let selectedEngine, !selectedEngine.isEmpty else { return nil }
        guard selectedEngine != primaryEngineId else { return nil }
        guard let engine = resolvedEngine else { return nil }
        guard modelManager.canUseForTranscription(engine), engine.isConfigured else { return nil }
        guard task != .translate || engine.supportsTranslation else { return nil }

        if let selectedModel {
            let modelIds = Set((engine.modelCatalog + engine.transcriptionModels).map(\.id))
            guard modelIds.contains(selectedModel) else { return nil }
        }

        return DictationRecoveryFallbackConfiguration(
            engineId: selectedEngine,
            modelId: selectedModel
        )
    }

    func transcribe() {
        guard canTranscribe, let recovery = selectedRecovery else { return }

        let recoveryID = recovery.id
        let url = recovery.url
        updateRecovery(id: recoveryID) { item in
            item.state = .loading
            item.errorMessage = nil
        }

        Task {
            do {
                let samples = try await audioSamplesLoader(url)
                updateRecovery(id: recoveryID) { item in
                    item.state = .transcribing
                }
                let result = try await transcriptionRunner(
                    samples,
                    languageSelection,
                    selectedTask,
                    selectedEngine,
                    selectedModel
                )

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    updateRecovery(id: recoveryID) { item in
                        item.state = .error
                        item.errorMessage = localizedAppText("No speech recognized", de: "Keine Sprache erkannt")
                    }
                    return
                }

                usageStatisticsRecorder?.recordTranscription(
                    timestamp: Date(),
                    wordsCount: text.split(separator: " ").count,
                    durationSeconds: result.duration,
                    appBundleIdentifier: Bundle.main.bundleIdentifier
                )

                let historyID = UUID()
                historyService.addRecord(
                    id: historyID,
                    rawText: result.text,
                    finalText: text,
                    appName: localizedAppText("Dictation Recovery", de: "Dictation-Recovery"),
                    appBundleIdentifier: Bundle.main.bundleIdentifier,
                    durationSeconds: result.duration,
                    language: result.detectedLanguage ?? languageSelection.requestedLanguage,
                    engineUsed: result.engineUsed,
                    modelUsed: historyModelDisplayName(result: result),
                    audioSamples: samples,
                    pipelineSteps: [localizedAppText("Recovered recording", de: "Wiederhergestellte Aufnahme")]
                )
                lastSavedRecoveryFileName = url.lastPathComponent
                lastSavedHistoryRecordID = historyID
                audioRecordingService.discardRecoveryRecording(at: url)
                updateRecoveryURLs(audioRecordingService.recoveryRecordingURLs)
            } catch {
                updateRecovery(id: recoveryID) { item in
                    item.state = .error
                    item.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func discardRecovery() {
        discardSelectedRecovery()
    }

    func discardSelectedRecovery() {
        guard let recovery = selectedRecovery else { return }
        discardRecovery(recovery)
    }

    func discardRecovery(_ recovery: RecoveryItem) {
        audioRecordingService.discardRecoveryRecording(at: recovery.url)
        updateRecoveryURLs(audioRecordingService.recoveryRecordingURLs)
    }

    private func updateRecoveryURLs(_ urls: [URL]) {
        let previousRecoveries = Dictionary(uniqueKeysWithValues: recoveries.map { ($0.id, $0) })
        let updatedRecoveries = urls.map { url in
            previousRecoveries[url.path] ?? RecoveryItem(url: url)
        }
        let selectedID = selectedRecoveryID

        recoveries = updatedRecoveries

        if let selectedID,
           recoveries.contains(where: { $0.id == selectedID }) {
            selectedRecoveryID = selectedID
        } else {
            selectedRecoveryID = recoveries.first?.id
        }
    }

    private func updateRecovery(id: RecoveryItem.ID, _ update: (inout RecoveryItem) -> Void) {
        guard let index = recoveries.firstIndex(where: { $0.id == id }) else { return }
        update(&recoveries[index])
    }

    private func historyModelDisplayName(result: TranscriptionResult) -> String {
        guard PluginManager.shared != nil else {
            return selectedModel ?? selectedEngine ?? result.engineUsed
        }

        return modelManager.resolvedModelDisplayName(
            engineOverrideId: selectedEngine,
            cloudModelOverride: selectedModel
        ) ?? selectedModel ?? selectedEngine ?? result.engineUsed
    }

    private var selectedEngineIsReady: Bool {
        if let engineReadinessChecker {
            return engineReadinessChecker(selectedEngine)
        }

        guard let engine = resolvedEngine else { return false }
        guard modelManager.canUseForTranscription(engine) else { return false }
        return engine.isConfigured
    }

    private func reconcileSelectionWithAvailablePlugins() {
        guard let pluginManager = PluginManager.shared else { return }
        if let selectedEngine,
           pluginManager.transcriptionEngine(for: selectedEngine) == nil {
            self.selectedEngine = nil
            selectedModel = nil
        }
        normalizeLanguageSelectionForResolvedEngine()
    }

    private func normalizeLanguageSelectionForResolvedEngine() {
        guard let engine = resolvedEngine else { return }
        let normalized = languageSelection.normalizedForSupportedLanguages(engine.supportedLanguages)
        if normalized != languageSelection {
            languageSelection = normalized
        }
    }
}
