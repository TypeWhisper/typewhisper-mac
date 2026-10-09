import Foundation
import AppKit
import Combine
import TypeWhisperPluginSDK

@MainActor
final class WatchFolderViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: WatchFolderViewModel?
    static var shared: WatchFolderViewModel {
        guard let instance = _shared else {
            fatalError("WatchFolderViewModel not initialized")
        }
        return instance
    }

    @Published var watchFolderPath: String?
    @Published var outputFolderPath: String?
    @Published var outputFormat: WatchFolderOutputFormat = .markdown {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: UserDefaultsKeys.watchFolderOutputFormat) }
    }
    @Published var detectSpeakers: Bool = false {
        didSet { UserDefaults.standard.set(detectSpeakers, forKey: UserDefaultsKeys.watchFolderDetectSpeakers) }
    }
    @Published var deleteSourceFiles: Bool = false {
        didSet { UserDefaults.standard.set(deleteSourceFiles, forKey: UserDefaultsKeys.watchFolderDeleteSource) }
    }
    @Published var autoStartOnLaunch: Bool = false {
        didSet { UserDefaults.standard.set(autoStartOnLaunch, forKey: UserDefaultsKeys.watchFolderAutoStart) }
    }
    @Published var languageSelection: LanguageSelection = .auto {
        didSet {
            UserDefaults.standard.set(
                languageSelection.storedValue(nilBehavior: .auto),
                forKey: UserDefaultsKeys.watchFolderLanguage
            )
        }
    }
    @Published var selectedEngine: String? {
        didSet {
            UserDefaults.standard.set(selectedEngine, forKey: UserDefaultsKeys.watchFolderEngine)
            guard isInitialized else { return }
            // Reset model and language when engine changes
            selectedModel = nil
            guard let selectedEngine,
                  let engine = PluginManager.shared.transcriptionEngine(for: selectedEngine) else { return }
            let normalized = languageSelection.normalizedForSupportedLanguages(engine.supportedLanguages)
            if normalized != languageSelection {
                languageSelection = normalized
            }
        }
    }
    @Published var selectedModel: String? {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: UserDefaultsKeys.watchFolderModel)
            guard isInitialized, oldValue != selectedModel, !isSelectedEngineMissing,
                  let engine = resolvedEngine else { return }
            let normalized = languageSelection.normalizedForSupportedLanguages(
                engine.supportedLanguages(forModel: selectedModel)
            )
            if normalized != languageSelection {
                languageSelection = normalized
            }
        }
    }

    private var isInitialized = false

    struct TranscriptionOverrides {
        let engineId: String?
        let modelId: String?
        let languageSelection: LanguageSelection
        /// Labels the output by speaker (Premium).
        var detectSpeakers = false
    }

    var transcriptionOverrides: TranscriptionOverrides {
        TranscriptionOverrides(
            engineId: availableSelectedEngine,
            modelId: availableSelectedModel,
            languageSelection: languageSelection,
            detectSpeakers: detectSpeakers
        )
    }

    var availableEngines: [TranscriptionEnginePlugin] {
        PluginManager.shared.transcriptionEngines
    }

    /// The chosen engine while its plugin is loaded. A plugin that is gone for
    /// now, as during an update, keeps the choice saved; files use the default
    /// engine until it is back.
    var availableSelectedEngine: String? {
        guard let selectedEngine,
              PluginManager.shared?.transcriptionEngine(for: selectedEngine) != nil else { return nil }
        return selectedEngine
    }
    /// The model choice, unless it belongs to an engine that is gone for now.
    var availableSelectedModel: String? {
        isSelectedEngineMissing ? nil : selectedModel
    }
    private var isSelectedEngineMissing: Bool {
        selectedEngine != nil && availableSelectedEngine == nil
    }
    /// The engine picker's selection; it shows the default engine while the
    /// chosen one is gone.
    var engineChoice: String? {
        get { availableSelectedEngine }
        set { selectedEngine = newValue }
    }
    var modelChoice: String? {
        get { availableSelectedModel }
        set {
            // The picker shows the default engine in place of a missing one,
            // so a model chosen there is for the default engine.
            if isSelectedEngineMissing { selectedEngine = nil }
            selectedModel = newValue
        }
    }

    var resolvedEngine: TranscriptionEnginePlugin? {
        let engineId = availableSelectedEngine ?? modelManager.selectedProviderId
        guard let engineId else { return nil }
        return PluginManager.shared.transcriptionEngine(for: engineId)
    }

    var selectedEngineSupportedLanguages: [String] {
        guard let engine = resolvedEngine else { return [] }
        return engine.supportedLanguages(forModel: availableSelectedModel).sorted()
    }

    let watchFolderService: WatchFolderService
    private let modelManager: ModelManagerService
    private var cancellables = Set<AnyCancellable>()

    init(
        watchFolderService: WatchFolderService,
        modelManager: ModelManagerService
    ) {
        self.watchFolderService = watchFolderService
        self.modelManager = modelManager
        loadSettings()
        isInitialized = true

        watchFolderService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func observePluginManager() {
        PluginManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileSelectionWithAvailablePlugins()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        PluginManager.shared.uninstalledTranscriptionEngines
            .sink { [weak self] providerIds in self?.forgetUninstalledEngines(providerIds) }
            .store(in: &cancellables)
    }

    /// An uninstalled engine's choice goes; one that is only gone for now stays.
    private func forgetUninstalledEngines(_ providerIds: Set<String>) {
        guard let selectedEngine, providerIds.contains(selectedEngine) else { return }
        self.selectedEngine = nil
        selectedModel = nil
    }

    func canPrepareForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        modelManager.canPrepareForTranscription(engine)
    }

    func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "watchFolder.selectFolder.message")

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.watchFolderBookmark)
                watchFolderPath = url.path
            }
        }
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "watchFolder.selectOutputFolder.message")

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.watchFolderOutputBookmark)
                outputFolderPath = url.path
            }
        }
    }

    func clearOutputFolder() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.watchFolderOutputBookmark)
        outputFolderPath = nil
    }

    func toggleWatching() {
        if watchFolderService.isWatching {
            watchFolderService.stopWatching()
        } else if let url = resolveWatchFolderURL() {
            watchFolderService.startWatching(folderURL: url)
        }
    }

    // MARK: - Private

    private func loadSettings() {
        outputFormat = WatchFolderOutputFormat(
            storedValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderOutputFormat)
        )
        deleteSourceFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderDeleteSource)
        detectSpeakers = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderDetectSpeakers)
        autoStartOnLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart)
        languageSelection = LanguageSelection(
            storedValue: UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderLanguage),
            nilBehavior: .auto
        )
        selectedEngine = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderEngine)
        selectedModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderModel)

        // Resolve watch folder bookmark
        if let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                watchFolderPath = url.path
            }
        }

        // Resolve output folder bookmark
        if let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderOutputBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                outputFolderPath = url.path
            }
        }
    }

    func reconcileSelectionWithAvailablePlugins() {
        if let selectedEngine {
            // A plugin that is gone for now keeps the choice and its language.
            guard let engine = PluginManager.shared.transcriptionEngine(for: selectedEngine) else { return }
            // An update can drop the chosen model; it then no longer applies.
            let modelIds = Set((engine.modelCatalog + engine.transcriptionModels).map(\.id))
            if let selectedModel, !modelIds.isEmpty, !modelIds.contains(selectedModel) {
                self.selectedModel = nil
            }
            let normalized = languageSelection.normalizedForSupportedLanguages(
                engine.supportedLanguages(forModel: selectedModel)
            )
            if normalized != languageSelection {
                languageSelection = normalized
            }
            return
        }

        if let engine = resolvedEngine {
            let normalized = languageSelection.normalizedForSupportedLanguages(
                engine.supportedLanguages(forModel: selectedModel)
            )
            if normalized != languageSelection {
                languageSelection = normalized
            }
        }
    }

    private func resolveWatchFolderURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
    }
}
