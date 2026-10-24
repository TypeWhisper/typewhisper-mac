import Foundation
import Combine
import os

/// Launch-phase signposts for Instruments. They appear in the Points of Interest
/// lane of the Time Profiler and App Launch templates.
///
/// Payloads are content-free: static names, plus the manifest id for per-plugin
/// intervals. Nothing is recorded unless a signpost-aware tool is capturing.
enum LaunchSignposts {
    static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: AppConstants.loggerSubsystem, category: .pointsOfInterest)
    )

    @MainActor private static var launchState: OSSignpostIntervalState?
    @MainActor private static var firstIdleObserver: CFRunLoopObserver?

    /// Opens the whole-launch interval and closes it at the first time the main run
    /// loop is about to wait, marked by the `Launch.firstIdle` event. This can happen
    /// before the delayed initial window opens, so it is not a rendered-frame marker.
    @MainActor
    static func beginLaunch() {
        guard launchState == nil else { return }
        launchState = signposter.beginInterval("Launch")

        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated {
                finishLaunch()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        firstIdleObserver = observer
    }

    @MainActor
    private static func finishLaunch() {
        firstIdleObserver = nil
        signposter.emitEvent("Launch.firstIdle")
        if let launchState {
            signposter.endInterval("Launch", launchState)
        }
    }
}

@MainActor
final class ServiceContainer: ObservableObject {
    static let shared = ServiceContainer()

    // Services
    let launchAtLoginController: LaunchAtLoginController
    let modelManagerService: ModelManagerService
    let audioFileService: AudioFileService
    let audioRecordingService: AudioRecordingService
    let hotkeyService: HotkeyService
    let textInsertionService: TextInsertionService
    let historyService: HistoryService
    let historySyncPreferences: HistorySyncPreferences
    let usageStatisticsService: UsageStatisticsService
    let recentTranscriptionStore: RecentTranscriptionStore
    let textDiffService: TextDiffService
    let profileService: ProfileService
    let workflowService: WorkflowService
    let translationService: AnyObject? // TranslationService (macOS 15+)
    let audioDuckingService: AudioDuckingService
    let mediaPlaybackService: MediaPlaybackService
    let dictionaryService: DictionaryService
    let dictionaryTrainingService: DictionaryTrainingService
    let targetAppCorrectionLearningService: TargetAppCorrectionLearningService
    let snippetService: SnippetService
    let userDataSyncStore: TypeWhisperUserDataSyncStore
    let cloudFolderSyncController: CloudFolderSyncController
    let soundService: SoundService
    let audioDeviceService: AudioDeviceService
    let promptActionService: PromptActionService
    let promptProcessingService: PromptProcessingService
    let pluginManager: PluginManager
    let termPackRegistryService: TermPackRegistryService
    let widgetDataService: WidgetDataService
    let appFormatterService: AppFormatterService
    let dictationPunctuationProfileStore: DictationPunctuationProfileStore
    let punctuationRulesLoader: PunctuationRulesLoader
    let punctuationStrategyResolver: PunctuationStrategyResolver
    let punctuationVerificationService: PunctuationVerificationService
    let audioRecorderService: AudioRecorderService
    let watchFolderService: WatchFolderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let errorLogService: ErrorLogService
    let speakerTranscriptCoordinator: SpeakerTranscriptCoordinator
    let speakerVoiceProfileService: SpeakerVoiceProfileService
    let calendarMeetingCountdownModel: CalendarMeetingCountdownModel
    let calendarMeetingAutomationController: CalendarMeetingAutomationController

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel

    // ViewModels
    let fileTranscriptionViewModel: FileTranscriptionViewModel
    /// File transcription for the Speakers page: every file gets a speaker transcript.
    let speakerTranscriptionViewModel: FileTranscriptionViewModel
    let dictationRecoveryViewModel: DictationRecoveryViewModel
    let settingsViewModel: SettingsViewModel
    let dictationViewModel: DictationViewModel
    let historyViewModel: HistoryViewModel
    lazy var historyRetranscriptionService = HistoryRetranscriptionEnvironment.makeService(self)
    let installedAppsViewModel: InstalledAppsViewModel
    let dictionaryViewModel: DictionaryViewModel
    let snippetsViewModel: SnippetsViewModel
    let homeViewModel: HomeViewModel
    let statisticsViewModel: StatisticsViewModel
    let audioRecorderViewModel: AudioRecorderViewModel
    let watchFolderViewModel: WatchFolderViewModel

    private init() {
        launchAtLoginController = LaunchAtLoginController()

        // Services
        let inputActivationGuard = AudioInputDeviceActivationGuard()
        modelManagerService = ModelManagerService()
        audioFileService = AudioFileService()
        audioRecordingService = AudioRecordingService(
            inputActivationGuard: inputActivationGuard,
            recoveryAudioStore: DictationRecoveryAudioStore(
                retentionPolicy: DictationRecoveryRetentionPolicy.load(from: .standard)
            )
        )
        hotkeyService = HotkeyService()
        textInsertionService = TextInsertionService()
        let historyPreferences = HistorySyncPreferences()
        historySyncPreferences = historyPreferences
        historyService = HistoryService(
            historySyncPreferences: historyPreferences
        )
        usageStatisticsService = UsageStatisticsService()
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
            snippetService: snippetService,
            historyService: historyService,
            historySyncPreferences: historyPreferences
        )
        soundService = SoundService()
        audioDeviceService = AudioDeviceService(
            inputActivationGuard: inputActivationGuard
        )
        promptProcessingService = PromptProcessingService()
        pluginManager = PluginManager()
        termPackRegistryService = TermPackRegistryService()
        widgetDataService = WidgetDataService(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        appFormatterService = AppFormatterService()
        dictationPunctuationProfileStore = DictationPunctuationProfileStore()
        punctuationRulesLoader = PunctuationRulesLoader()
        punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: dictationPunctuationProfileStore)
        punctuationVerificationService = PunctuationVerificationService(rulesLoader: punctuationRulesLoader)
        audioRecorderService = AudioRecorderService(
            inputActivationGuard: inputActivationGuard
        )
        promptProcessingService.modelManagerService = modelManagerService
        watchFolderService = WatchFolderService(audioFileService: audioFileService, modelManagerService: modelManagerService)
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        errorLogService = ErrorLogService()
        cloudFolderSyncController = CloudFolderSyncController(
            syncStore: userDataSyncStore,
            historyService: historyService,
            historySyncPreferences: historyPreferences
        )

        // ViewModels (created before HTTP API so DictationViewModel is available)
        fileTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            dictionaryService: dictionaryService,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        let recoveryViewModel = DictationRecoveryViewModel(
            audioRecordingService: audioRecordingService,
            modelManager: modelManagerService,
            historyService: historyService,
            audioFileService: audioFileService,
            usageStatisticsRecorder: usageStatisticsService
        )
        dictationRecoveryViewModel = recoveryViewModel
        settingsViewModel = SettingsViewModel(modelManager: modelManagerService)
        dictionaryTrainingService = DictionaryTrainingService(
            audioRecordingService: audioRecordingService,
            modelManager: modelManagerService,
            settingsViewModel: settingsViewModel,
            dictionaryService: dictionaryService
        )
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
            targetAppCorrectionLearningService: targetAppCorrectionLearningService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService,
            usageStatisticsRecorder: usageStatisticsService,
            recoveryFallbackConfigurationProvider: { [recoveryViewModel] primaryEngineId, task in
                recoveryViewModel.automaticFallbackConfiguration(
                    excluding: primaryEngineId,
                    task: task
                )
            },
            recoveryHedgeThresholdProvider: { [recoveryViewModel] in
                recoveryViewModel.automaticHedgeThreshold
            }
        )
        audioRecorderViewModel = AudioRecorderViewModel(
            recorderService: audioRecorderService,
            modelManager: modelManagerService,
            dictionaryService: dictionaryService,
            audioFileService: audioFileService,
            audioDeviceService: audioDeviceService,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        let speakerCoordinator = SpeakerTranscriptCoordinator(
            historyService: historyService,
            providerSource: { PluginManager.shared?.speakerDiarizationProviders.first }
        )
        speakerCoordinator.timingSource = { [audioFileService, modelManagerService] url, language in
            let samples = try await audioFileService.loadAudioSamples(from: url)
            return try await modelManagerService.transcribe(
                audioSamples: samples,
                languageSelection: language.map(LanguageSelection.exact) ?? .auto,
                task: .transcribe,
                onProgress: { _ in true },
                onSourceProgress: { _ in true }
            )
        }
        speakerVoiceProfileService = SpeakerVoiceProfileService(
            store: VoiceProfileStore(),
            historyService: historyService
        )
        speakerCoordinator.voices = speakerVoiceProfileService
        speakerTranscriptCoordinator = speakerCoordinator
        watchFolderService.speakerLabeler = { [speakerCoordinator] result, samples in
            try await speakerCoordinator.labelingSpeakers(in: result, samples: samples)
        }
        speakerTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            dictionaryService: dictionaryService,
            detectsSpeakers: true,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        speakerTranscriptionViewModel.speakerRecordIntake = { [speakerCoordinator] in
            await speakerCoordinator.addRecording($0)
        }
        speakerTranscriptionViewModel.speakerRecordRemoval = { [speakerCoordinator, historyService] recordID in
            speakerCoordinator.cancel(recordID: recordID)
            historyService.deleteRecord(withID: recordID)
        }
        audioRecorderViewModel.speakerRecordIntake = { [speakerCoordinator] in
            await speakerCoordinator.addRecording($0)
        }
        calendarMeetingCountdownModel = CalendarMeetingCountdownModel(
            hotkeyService: hotkeyService,
            onButtonAction: {
                ManagedAppReopenSuppression.shared.markBackgroundInteraction()
            }
        )
        calendarMeetingAutomationController = CalendarMeetingAutomationController(
            recorderViewModel: audioRecorderViewModel,
            dictationViewModel: dictationViewModel,
            countdownModel: calendarMeetingCountdownModel
        )


        // HTTP API
        let apiAuthenticator = LocalAPIAuthenticator()
        let router = APIRouter(
            authenticationProvider: apiAuthenticator.authenticationRequirement,
            tokenProvider: apiAuthenticator.currentToken
        )
        let settingsBackupService = SettingsBackupAutomationService(
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            profileService: profileService,
            promptActionService: promptActionService,
            pluginManager: pluginManager,
            historyService: historyService,
            usageStatisticsService: usageStatisticsService,
            liveFieldTranscriptEnabledDidChange: { [dictationViewModel] enabled in
                dictationViewModel.liveFieldTranscriptEnabled = enabled
            },
            recoveryRetentionPolicyDidChange: { [audioRecordingService] policy in
                _ = audioRecordingService.updateRecoveryRetentionPolicy(policy)
            },
            cancellationBehaviorDidChange: { [dictationViewModel] behavior in
                dictationViewModel.cancellationBehavior = behavior
            },
            indicatorThemeDidChange: { [dictationViewModel] theme in
                dictationViewModel.indicatorTheme = theme
            },
            dictationRecoveryPreferencesDidChange: { [recoveryViewModel] in
                recoveryViewModel.reloadPreferencesFromDefaults()
            },
            hotkeysDidChange: { [dictationViewModel] in
                dictationViewModel.reloadHotkeysFromDefaults()
            }
        )
        let handlers = APIHandlers(
            modelManager: modelManagerService,
            audioFileService: audioFileService,
            translationService: translationService,
            historyService: historyService,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecorderViewModel: audioRecorderViewModel,
            audioDeviceService: audioDeviceService,
            settingsBackupService: settingsBackupService,
            speakerCoordinator: speakerTranscriptCoordinator,
            speakerVoices: speakerVoiceProfileService
        )
        handlers.register(on: router)
        TextProcessingAPI.live(
            promptProcessingService: promptProcessingService,
            workflowService: workflowService,
            workflowTextProcessor: WorkflowTextProcessingService(
                promptProcessingService: promptProcessingService,
                translationService: translationService,
                workflowService: workflowService,
                vocabularyProvider: { [dictionaryService] in dictionaryService.vocabularyForPrompt() }
            )
        ).register(on: router)
        httpServer = HTTPServer(router: router)
        apiServerViewModel = APIServerViewModel(httpServer: httpServer, apiAuthenticator: apiAuthenticator)
        historyViewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService,
            syncController: cloudFolderSyncController
        )
        installedAppsViewModel = InstalledAppsViewModel()
        dictionaryViewModel = DictionaryViewModel(
            dictionaryService: dictionaryService,
            termPackRegistryService: termPackRegistryService,
            selectedTranscriptionEngine: { [modelManagerService] in
                modelManagerService.selectedProviderId.flatMap {
                    PluginManager.shared?.transcriptionEngine(for: $0)
                }
            }
        )
        snippetsViewModel = SnippetsViewModel(snippetService: snippetService)
        homeViewModel = HomeViewModel(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        statisticsViewModel = StatisticsViewModel(
            usageStatisticsService: usageStatisticsService
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
        DictionaryViewModel._shared = dictionaryViewModel
        SnippetsViewModel._shared = snippetsViewModel
        HomeViewModel._shared = homeViewModel
        StatisticsViewModel._shared = statisticsViewModel
        AudioRecorderViewModel._shared = audioRecorderViewModel
        WatchFolderViewModel._shared = watchFolderViewModel

        // Plugin system
        EventBus.shared = EventBus()
        PluginManager.shared = pluginManager
        TermPackRegistryService.shared = termPackRegistryService

        modelManagerService.observePluginManager()
        promptProcessingService.observePluginManager()
        fileTranscriptionViewModel.observePluginManager()
        speakerTranscriptionViewModel.observePluginManager()
        dictationRecoveryViewModel.observePluginManager()
        settingsViewModel.observePluginManager()
        audioRecorderViewModel.observePluginManager()
        watchFolderViewModel.observePluginManager()
    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }

        let signposter = LaunchSignposts.signposter
        let initializeState = signposter.beginInterval("Launch.initialize")
        defer { signposter.endInterval("Launch.initialize", initializeState) }

        calendarMeetingAutomationController.initialize()
        historyService.failInterruptedSpeakerTranscripts()
        speakerVoiceProfileService.removeEmbeddingsOfDeletedRecordings()

        hotkeyService.setup()
        dictationViewModel.registerInitialTriggerHotkeys()
        DictumWordCountRecount.runIfPending(history: historyService, usageStatistics: usageStatisticsService)
        usageStatisticsService.backfillFromHistoryIfNeeded {
            try historyService.allRecordsThrowing()
        }
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

        // Activation hydrates credentials and custom profiles before selection can settle.
        // Reconciliation also requests passive restore from the final selected engine.
        signposter.withIntervalSignpost("Launch.modelRestore") {
            modelManagerService.restoreProviderSelection()
        }
        audioRecorderViewModel.reconcileSelectionWithAvailablePlugins()
        watchFolderViewModel.reconcileSelectionWithAvailablePlugins()
        statisticsViewModel.refresh()

        // Validate LLM provider selection against loaded plugins
        promptProcessingService.validateSelectionAfterPluginLoad()

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
