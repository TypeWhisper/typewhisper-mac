import Foundation
import Combine

@MainActor
final class ServiceContainer: ObservableObject {
    static let shared = ServiceContainer()

    // Services
    let modelManagerService: ModelManagerService
    let audioFileService: AudioFileService
    let audioRecordingService: AudioRecordingService
    let hotkeyService: HotkeyService
    let textInsertionService: TextInsertionService
    let historyService: HistoryService
    let textDiffService: TextDiffService
    let profileService: ProfileService
    let translationService: AnyObject? // TranslationService (macOS 15+)
    let audioDuckingService: AudioDuckingService
    let dictionaryService: DictionaryService
    let snippetService: SnippetService
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let promptActionService: PromptActionService
    let promptProcessingService: PromptProcessingService
    let pluginManager: PluginManager
    let pluginRegistryService: PluginRegistryService
    let widgetDataService: WidgetDataService
    let memoryService: MemoryService
    let appFormatterService: AppFormatterService
    let audioRecorderService: AudioRecorderService
    let watchFolderService: WatchFolderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let speechFeedbackService: SpeechFeedbackService
    let errorLogService: ErrorLogService

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel

    // ViewModels
    let fileTranscriptionViewModel: FileTranscriptionViewModel
    let settingsViewModel: SettingsViewModel
    let dictationViewModel: DictationViewModel
    let historyViewModel: HistoryViewModel
    let profilesViewModel: ProfilesViewModel
    let dictionaryViewModel: DictionaryViewModel
    let snippetsViewModel: SnippetsViewModel
    let homeViewModel: HomeViewModel
    let promptActionsViewModel: PromptActionsViewModel
    let audioRecorderViewModel: AudioRecorderViewModel
    let watchFolderViewModel: WatchFolderViewModel

    private init() {
        // Services
        modelManagerService = ModelManagerService()
        audioFileService = AudioFileService()
        audioRecordingService = AudioRecordingService()
        hotkeyService = HotkeyService()
        textInsertionService = TextInsertionService()
        historyService = HistoryService()
        textDiffService = TextDiffService()
        profileService = ProfileService()
        #if canImport(Translation)
        if #available(macOS 15, *) {
            translationService = TranslationService()
        } else {
            translationService = nil
        }
        #else
        translationService = nil
        #endif
        audioDuckingService = AudioDuckingService()
        dictionaryService = DictionaryService()
        snippetService = SnippetService()
        soundService = SoundService()
        audioDeviceService = AudioDeviceService()
        promptActionService = PromptActionService()
        promptProcessingService = PromptProcessingService()
        pluginManager = PluginManager()
        pluginRegistryService = PluginRegistryService()
        widgetDataService = WidgetDataService(historyService: historyService)
        memoryService = MemoryService(promptProcessingService: promptProcessingService)
        appFormatterService = AppFormatterService()
        audioRecorderService = AudioRecorderService()
        promptProcessingService.memoryService = memoryService
        watchFolderService = WatchFolderService(audioFileService: audioFileService, modelManagerService: modelManagerService)
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        speechFeedbackService = SpeechFeedbackService()
        errorLogService = ErrorLogService()

        // ViewModels (created before HTTP API so DictationViewModel is available)
        fileTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService
        )
        settingsViewModel = SettingsViewModel(modelManager: modelManagerService)
        dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManagerService,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            profileService: profileService,
            translationService: translationService,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService
        )


        // HTTP API
        let router = APIRouter()
        let handlers = APIHandlers(modelManager: modelManagerService, audioFileService: audioFileService, translationService: translationService, historyService: historyService, profileService: profileService, dictationViewModel: dictationViewModel)
        handlers.register(on: router)
        httpServer = HTTPServer(router: router)
        apiServerViewModel = APIServerViewModel(httpServer: httpServer)
        historyViewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
        profilesViewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel
        )
        dictionaryViewModel = DictionaryViewModel(dictionaryService: dictionaryService)
        snippetsViewModel = SnippetsViewModel(snippetService: snippetService)
        homeViewModel = HomeViewModel(historyService: historyService)
        promptActionsViewModel = PromptActionsViewModel(
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService
        )
        audioRecorderViewModel = AudioRecorderViewModel(recorderService: audioRecorderService, modelManager: modelManagerService, dictionaryService: dictionaryService)
        watchFolderViewModel = WatchFolderViewModel(watchFolderService: watchFolderService)

        // Set shared references
        FileTranscriptionViewModel._shared = fileTranscriptionViewModel
        SettingsViewModel._shared = settingsViewModel
        DictationViewModel._shared = dictationViewModel
        APIServerViewModel._shared = apiServerViewModel
        HistoryViewModel._shared = historyViewModel
        ProfilesViewModel._shared = profilesViewModel
        DictionaryViewModel._shared = dictionaryViewModel
        SnippetsViewModel._shared = snippetsViewModel
        HomeViewModel._shared = homeViewModel
        PromptActionsViewModel._shared = promptActionsViewModel
        AudioRecorderViewModel._shared = audioRecorderViewModel
        WatchFolderViewModel._shared = watchFolderViewModel

        // Plugin system
        EventBus.shared = EventBus()
        PluginManager.shared = pluginManager
        PluginRegistryService.shared = pluginRegistryService

        settingsViewModel.observePluginManager()
    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }

        hotkeyService.setup()
        dictationViewModel.registerInitialProfileHotkeys()
        let retentionDays = UserDefaults.standard.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        if retentionDays > 0 { historyService.purgeOldRecords(retentionDays: retentionDays) }

        if apiServerViewModel.isEnabled {
            apiServerViewModel.startServer()
        }

        pluginManager.setProfileNamesProvider { [weak self] in
            self?.profileService.profiles.map(\.name) ?? []
        }
        pluginManager.scanAndLoadPlugins()

        // Re-restore provider selection now that plugins are loaded
        modelManagerService.restoreProviderSelection()

        // Validate LLM provider selection against loaded plugins
        promptProcessingService.validateSelectionAfterPluginLoad()

        // Check for plugin updates in background
        pluginRegistryService.checkForUpdatesInBackground()

        // Start memory service
        memoryService.startListening()

        // Auto-start watch folder if configured
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart),
           let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                watchFolderService.startWatching(folderURL: url)
            }
        }

        // Migrate stale cloudModelOverride in profiles
        for profile in profileService.profiles {
            guard let modelOverride = profile.cloudModelOverride,
                  let engineOverride = profile.engineOverride,
                  let plugin = PluginManager.shared.transcriptionEngine(for: engineOverride) else { continue }
            let validIds = plugin.transcriptionModels.map(\.id)
            if !validIds.contains(modelOverride) {
                profile.cloudModelOverride = nil
            }
        }
    }
}
