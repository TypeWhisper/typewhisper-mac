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
    let translationService: TranslationService
    let audioDuckingService: AudioDuckingService
    let mediaPlaybackService: MediaPlaybackService
    let dictionaryService: DictionaryService
    let snippetService: SnippetService
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let promptActionService: PromptActionService
    let promptProcessingService: PromptProcessingService
    let pluginManager: PluginManager

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel

    // ViewModels
    let modelManagerViewModel: ModelManagerViewModel
    let fileTranscriptionViewModel: FileTranscriptionViewModel
    let settingsViewModel: SettingsViewModel
    let dictationViewModel: DictationViewModel
    let historyViewModel: HistoryViewModel
    let profilesViewModel: ProfilesViewModel
    let dictionaryViewModel: DictionaryViewModel
    let snippetsViewModel: SnippetsViewModel
    let homeViewModel: HomeViewModel
    let promptActionsViewModel: PromptActionsViewModel

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
        translationService = TranslationService()
        audioDuckingService = AudioDuckingService()
        mediaPlaybackService = MediaPlaybackService()
        dictionaryService = DictionaryService()
        snippetService = SnippetService()
        soundService = SoundService()
        audioDeviceService = AudioDeviceService()
        promptActionService = PromptActionService()
        promptProcessingService = PromptProcessingService()
        pluginManager = PluginManager()

        // ViewModels (created before HTTP API so DictationViewModel is available)
        modelManagerViewModel = ModelManagerViewModel(modelManager: modelManagerService)
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
            mediaPlaybackService: mediaPlaybackService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService
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

        // Set shared references
        ModelManagerViewModel._shared = modelManagerViewModel
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

        // Plugin system
        EventBus.shared = EventBus()
        PluginManager.shared = pluginManager
    }

    func initialize() async {
        hotkeyService.setup()
        dictationViewModel.registerInitialProfileHotkeys()
        let retentionDays = UserDefaults.standard.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        if retentionDays > 0 { historyService.purgeOldRecords(retentionDays: retentionDays) }

        if apiServerViewModel.isEnabled {
            apiServerViewModel.startServer()
        }

        // Register SpeechAnalyzer model provider on macOS 26+
        if #available(macOS 26, *) {
            await SpeechAnalyzerModelProvider.populateCache()
            ModelInfo._speechAnalyzerModelProvider = { SpeechAnalyzerModelProvider.availableModels() }
            // Refresh model list now that provider is available
            modelManagerViewModel.models = ModelInfo.models(for: modelManagerViewModel.selectedEngine)
        }

        await modelManagerService.loadAllSavedModels()

        pluginManager.setProfileNamesProvider { [weak self] in
            self?.profileService.profiles.map(\.name) ?? []
        }
        pluginManager.scanAndLoadPlugins()

        // Re-restore cloud model selection now that plugins are loaded
        modelManagerService.restoreCloudModelSelection()

        // Validate LLM provider selection against loaded plugins
        promptProcessingService.validateSelectionAfterPluginLoad()

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
