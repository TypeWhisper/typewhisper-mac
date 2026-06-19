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
    let recentTranscriptionStore: RecentTranscriptionStore
    let textDiffService: TextDiffService
    let profileService: ProfileService
    let workflowService: WorkflowService
    let translationService: AnyObject? // TranslationService (macOS 15+)
    let audioDuckingService: AudioDuckingService
    let mediaPlaybackService: MediaPlaybackService
    let dictionaryService: DictionaryService
    let targetAppCorrectionLearningService: TargetAppCorrectionLearningService
    let snippetService: SnippetService
    let userDataSyncStore: TypeWhisperUserDataSyncStore
    let cloudFolderSyncController: CloudFolderSyncController
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let promptActionService: PromptActionService
    let promptProcessingService: PromptProcessingService
    let pluginManager: PluginManager
    let pluginRegistryService: PluginRegistryService
    let termPackRegistryService: TermPackRegistryService
    let widgetDataService: WidgetDataService
    let memoryService: MemoryService
    let appFormatterService: AppFormatterService
    let dictationPunctuationProfileStore: DictationPunctuationProfileStore
    let punctuationRulesLoader: PunctuationRulesLoader
    let punctuationStrategyResolver: PunctuationStrategyResolver
    let punctuationVerificationService: PunctuationVerificationService
    let audioRecorderService: AudioRecorderService
    let watchFolderService: WatchFolderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let speechFeedbackService: SpeechFeedbackService
    let errorLogService: ErrorLogService
    let licenseService: LicenseService
    let supporterDiscordService: SupporterDiscordService

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel

    // ViewModels
    let fileTranscriptionViewModel: FileTranscriptionViewModel
    let dictationRecoveryViewModel: DictationRecoveryViewModel
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
        let inputActivationGuard = AudioInputDeviceActivationGuard()
        modelManagerService = ModelManagerService()
        audioFileService = AudioFileService()
        audioRecordingService = AudioRecordingService(
            inputActivationGuard: inputActivationGuard
        )
        hotkeyService = HotkeyService()
        textInsertionService = TextInsertionService()
        historyService = HistoryService()
        recentTranscriptionStore = RecentTranscriptionStore()
        textDiffService = TextDiffService()
        profileService = ProfileService()
        workflowService = WorkflowService()
        promptActionService = PromptActionService()
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
        mediaPlaybackService = MediaPlaybackService()
        dictionaryService = DictionaryService()
        targetAppCorrectionLearningService = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
        snippetService = SnippetService()
        userDataSyncStore = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )
        soundService = SoundService()
        audioDeviceService = AudioDeviceService(
            inputActivationGuard: inputActivationGuard
        )
        promptProcessingService = PromptProcessingService()
        pluginManager = PluginManager()
        pluginRegistryService = PluginRegistryService()
        termPackRegistryService = TermPackRegistryService()
        widgetDataService = WidgetDataService(historyService: historyService)
        memoryService = MemoryService(promptProcessingService: promptProcessingService)
        appFormatterService = AppFormatterService()
        dictationPunctuationProfileStore = DictationPunctuationProfileStore()
        punctuationRulesLoader = PunctuationRulesLoader()
        punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: dictationPunctuationProfileStore)
        punctuationVerificationService = PunctuationVerificationService(rulesLoader: punctuationRulesLoader)
        audioRecorderService = AudioRecorderService()
        promptProcessingService.memoryService = memoryService
        promptProcessingService.modelManagerService = modelManagerService
        watchFolderService = WatchFolderService(audioFileService: audioFileService, modelManagerService: modelManagerService)
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        speechFeedbackService = SpeechFeedbackService()
        errorLogService = ErrorLogService()
        licenseService = LicenseService()
        supporterDiscordService = SupporterDiscordService(licenseService: licenseService)
        cloudFolderSyncController = CloudFolderSyncController(
            licenseService: licenseService,
            syncStore: userDataSyncStore
        )

        // ViewModels (created before HTTP API so DictationViewModel is available)
        fileTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService
        )
        dictationRecoveryViewModel = DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: modelManagerService,
            historyService: historyService,
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
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: translationService,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            licenseService: licenseService,
            targetAppCorrectionLearningService: targetAppCorrectionLearningService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService
        )
        audioRecorderViewModel = AudioRecorderViewModel(
            recorderService: audioRecorderService,
            modelManager: modelManagerService,
            dictionaryService: dictionaryService
        )


        // HTTP API
        let apiAuthenticator = LocalAPIAuthenticator()
        let router = APIRouter(apiTokenProvider: apiAuthenticator.tokenForEnforcedRequests)
        let handlers = APIHandlers(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            translationService: translationService,
            historyService: historyService,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecorderViewModel: audioRecorderViewModel
        )
        handlers.register(on: router)
        httpServer = HTTPServer(router: router)
        apiServerViewModel = APIServerViewModel(httpServer: httpServer, apiAuthenticator: apiAuthenticator)
        historyViewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService
        )
        profilesViewModel = ProfilesViewModel(
            profileService: profileService,
            historyService: historyService,
            settingsViewModel: settingsViewModel,
            textInsertionService: textInsertionService
        )
        dictionaryViewModel = DictionaryViewModel(
            dictionaryService: dictionaryService,
            licenseService: licenseService,
            termPackRegistryService: termPackRegistryService
        )
        snippetsViewModel = SnippetsViewModel(snippetService: snippetService)
        homeViewModel = HomeViewModel(historyService: historyService)
        promptActionsViewModel = PromptActionsViewModel(
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            profileService: profileService
        )
        watchFolderViewModel = WatchFolderViewModel(
            watchFolderService: watchFolderService,
            modelManager: modelManagerService
        )

        // Set shared references
        FileTranscriptionViewModel._shared = fileTranscriptionViewModel
        DictationRecoveryViewModel._shared = dictationRecoveryViewModel
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

        // License
        LicenseService.shared = licenseService
        SupporterDiscordService.shared = supporterDiscordService

        // Plugin system
        EventBus.shared = EventBus()
        PluginManager.shared = pluginManager
        PluginRegistryService.shared = pluginRegistryService
        TermPackRegistryService.shared = termPackRegistryService

        modelManagerService.observePluginManager()
        promptProcessingService.observePluginManager()
        fileTranscriptionViewModel.observePluginManager()
        dictationRecoveryViewModel.observePluginManager()
        settingsViewModel.observePluginManager()
        audioRecorderViewModel.observePluginManager()
        watchFolderViewModel.observePluginManager()
    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }

        hotkeyService.setup()
        dictationViewModel.registerInitialTriggerHotkeys()
        let retentionDays = UserDefaults.standard.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        if retentionDays > 0 { historyService.purgeOldRecords(retentionDays: retentionDays) }

        if apiServerViewModel.isEnabled {
            apiServerViewModel.startServer()
        }

        pluginManager.setRuleNamesProvider { [weak self] in
            self?.workflowService.availableRuleNames ?? []
        }
        pluginManager.setWorkflowProvider { [weak self] in
            self?.workflowService.workflows.map(\.pluginWorkflowInfo) ?? []
        }
        pluginManager.scanAndLoadPlugins()

        // Re-restore provider selection now that plugins are loaded
        modelManagerService.restoreProviderSelection()
        audioRecorderViewModel.reconcileSelectionWithAvailablePlugins()
        watchFolderViewModel.reconcileSelectionWithAvailablePlugins()

        // Validate LLM provider selection against loaded plugins
        promptProcessingService.validateSelectionAfterPluginLoad()

        pluginRegistryService.checkForUpdatesInBackground()

        // Start memory service
        memoryService.startListening()

        // Validate license if needed
        await licenseService.validateIfNeeded()
        await licenseService.validateSupporterIfNeeded()
        await supporterDiscordService.refreshStatusIfNeeded()

        // Auto-start watch folder if configured
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart),
           let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                watchFolderService.startWatching(folderURL: url)
            }
        }

    }
}
