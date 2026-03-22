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
    @Published var outputFormat: String = "md" {
        didSet { UserDefaults.standard.set(outputFormat, forKey: UserDefaultsKeys.watchFolderOutputFormat) }
    }
    @Published var deleteSourceFiles: Bool = false {
        didSet { UserDefaults.standard.set(deleteSourceFiles, forKey: UserDefaultsKeys.watchFolderDeleteSource) }
    }
    @Published var autoStartOnLaunch: Bool = false {
        didSet { UserDefaults.standard.set(autoStartOnLaunch, forKey: UserDefaultsKeys.watchFolderAutoStart) }
    }
    @Published var language: String? {
        didSet { UserDefaults.standard.set(language, forKey: UserDefaultsKeys.watchFolderLanguage) }
    }
    @Published var selectedEngine: String? {
        didSet {
            UserDefaults.standard.set(selectedEngine, forKey: UserDefaultsKeys.watchFolderEngine)
            guard isInitialized else { return }
            // Reset model and language when engine changes
            selectedModel = nil
            let supported = selectedEngineSupportedLanguages
            if let lang = language, !supported.isEmpty, !supported.contains(lang) {
                language = nil
            }
        }
    }
    @Published var selectedModel: String? {
        didSet { UserDefaults.standard.set(selectedModel, forKey: UserDefaultsKeys.watchFolderModel) }
    }

    private var isInitialized = false

    struct TranscriptionOverrides {
        let engineId: String?
        let modelId: String?
        let language: String?
    }

    var transcriptionOverrides: TranscriptionOverrides {
        TranscriptionOverrides(engineId: selectedEngine, modelId: selectedModel, language: language)
    }

    var availableEngines: [TranscriptionEnginePlugin] {
        PluginManager.shared.transcriptionEngines
    }

    var resolvedEngine: TranscriptionEnginePlugin? {
        let engineId = selectedEngine ?? ServiceContainer.shared.modelManagerService.selectedProviderId
        guard let engineId else { return nil }
        return PluginManager.shared.transcriptionEngine(for: engineId)
    }

    var selectedEngineSupportedLanguages: [String] {
        guard let engine = resolvedEngine else { return [] }
        return engine.supportedLanguages.sorted()
    }

    let watchFolderService: WatchFolderService
    private var cancellables = Set<AnyCancellable>()

    init(watchFolderService: WatchFolderService) {
        self.watchFolderService = watchFolderService
        loadSettings()
        isInitialized = true

        watchFolderService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
        outputFormat = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderOutputFormat) ?? "md"
        deleteSourceFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderDeleteSource)
        autoStartOnLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart)
        language = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderLanguage)
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

    private func resolveWatchFolderURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
    }
}
