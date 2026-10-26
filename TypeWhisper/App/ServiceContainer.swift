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
    let managedPolicyService: ManagedPolicyService
    let managedUpdateCoordinator: ManagedUpdateCoordinator
    let launchAtLoginController: LaunchAtLoginPolicyController
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
    let pluginRegistryService: PluginRegistryService
    let termPackRegistryService: TermPackRegistryService
    let localTermPackStore: LocalTermPackStore
    let widgetDataService: WidgetDataService
    let memoryService: MemoryService
    let appFormatterService: AppFormatterService
    let dictationPunctuationProfileStore: DictationPunctuationProfileStore
    let punctuationRulesLoader: PunctuationRulesLoader
    let punctuationStrategyResolver: PunctuationStrategyResolver
    let punctuationVerificationService: PunctuationVerificationService
    let audioRecorderService: AudioRecorderService
    let recorderFolderStore: RecorderFolderStore
    let watchFolderService: WatchFolderService
    let accessibilityAnnouncementService: AccessibilityAnnouncementService
    let speechFeedbackService: SpeechFeedbackService
    let errorLogService: ErrorLogService
    let licenseService: LicenseService
    let premiumAccountService: PremiumAccountService
    #if APPSTORE
    let appStorePremiumService: AppStorePremiumService
    #endif
    let supporterDiscordService: SupporterDiscordService
    let speakerTranscriptCoordinator: SpeakerTranscriptCoordinator
    let speakerVoiceProfileService: SpeakerVoiceProfileService
    let calendarMeetingCountdownModel: CalendarMeetingCountdownModel
    let calendarMeetingAutomationController: CalendarMeetingAutomationController

    // HTTP API
    let httpServer: HTTPServer
    let apiServerViewModel: APIServerViewModel
    let remoteLinkServer: RemoteLinkServer
    let remoteLinkViewModel: RemoteLinkViewModel

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

    private var managedPolicySubscription: AnyCancellable?

    private init() {
        // Managed preferences are read before any service that may consult them.
        managedPolicyService = ManagedPolicyService(
            source: AppConstants.isRunningTests ? EmptyManagedPolicySource() : ManagedPreferencesPolicySource(),
            snapshotStore: .shared
        )
        managedPolicyService.refresh()
        managedUpdateCoordinator = ManagedUpdateCoordinator(policyService: managedPolicyService)
        launchAtLoginController = LaunchAtLoginPolicyController(snapshot: managedPolicyService.current)

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
        workflowService.onScreenContextWorkflowsAvailable = {
            // Asynchronous, so the system prompt never interrupts a save or app startup.
            DispatchQueue.main.async { ScreenContextService.requestPermissionIfNeeded() }
        }
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
        pluginRegistryService = PluginRegistryService()
        termPackRegistryService = TermPackRegistryService()
        localTermPackStore = LocalTermPackStore(
            directory: AppConstants.appSupportDirectory
                .appendingPathComponent(LocalTermPackStore.directoryName, isDirectory: true)
        )
        widgetDataService = WidgetDataService(
            historyService: historyService,
            usageStatisticsService: usageStatisticsService
        )
        memoryService = MemoryService(promptProcessingService: promptProcessingService)
        appFormatterService = AppFormatterService()
        dictationPunctuationProfileStore = DictationPunctuationProfileStore()
        punctuationRulesLoader = PunctuationRulesLoader()
        punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: dictationPunctuationProfileStore)
        punctuationVerificationService = PunctuationVerificationService(rulesLoader: punctuationRulesLoader)
        recorderFolderStore = RecorderFolderStore()
        audioRecorderService = AudioRecorderService(
            inputActivationGuard: inputActivationGuard,
            folderStore: recorderFolderStore
        )
        promptProcessingService.memoryService = memoryService
        promptProcessingService.modelManagerService = modelManagerService
        watchFolderService = WatchFolderService(audioFileService: audioFileService, modelManagerService: modelManagerService)
        accessibilityAnnouncementService = AccessibilityAnnouncementService()
        pluginRegistryService.accessibilityAnnouncementService = accessibilityAnnouncementService
        speechFeedbackService = SpeechFeedbackService()
        errorLogService = ErrorLogService()
        licenseService = LicenseService()
        premiumAccountService = AppConstants.isRunningTests
            ? PremiumAccountService(
                isSignedInOverride: false,
                automaticallyRefresh: false
            )
            : PremiumAccountService()
        #if APPSTORE
        appStorePremiumService = AppStorePremiumService(
            licenseService: licenseService,
            premiumAccountService: premiumAccountService
        )
        // The sync controller below reads Premium access while it starts.
        AppStorePremiumService.shared = appStorePremiumService
        #endif
        supporterDiscordService = SupporterDiscordService(licenseService: licenseService)
        cloudFolderSyncController = CloudFolderSyncController(
            premiumAccountService: premiumAccountService,
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
            usageStatisticsRecorder: usageStatisticsService,
            licenseService: licenseService
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
            providerSource: { PluginManager.shared?.speakerDiarizationProviders.first },
            premiumAccess: { [licenseService, premiumAccountService] in
                SpeakerWorkspacePremiumAccess.isGranted(
                    hasCommercialLicense: licenseService.hasCommercialLicense,
                    hasPremiumEntitlement: premiumAccountService.hasPremiumEntitlement
                )
            }
        )
        speakerCoordinator.observePremiumChanges([
            licenseService.objectWillChange.eraseToAnyPublisher(),
            premiumAccountService.objectWillChange.eraseToAnyPublisher(),
        ])
        // Parakeet reports when each word is spoken and runs on this Mac, so
        // it gives timing whatever engine wrote the text. Nil when it can't run.
        let parakeetTimingPass: @MainActor (URL, String?) async throws -> TranscriptionResult? = {
            [audioFileService, modelManagerService] url, language in
            let engineID = "parakeet"
            let log = Logger(subsystem: AppConstants.loggerSubsystem, category: "SpeakerTranscript")
            guard let engine = PluginManager.shared?.transcriptionEngine(for: engineID) else {
                log.info("Timing pass with Parakeet skipped: Parakeet is not installed")
                return nil
            }
            guard modelManagerService.canPrepareForTranscription(engine) else {
                log.info("Timing pass with Parakeet skipped: Parakeet has no model to load")
                return nil
            }
            // Engines store a code or a name ("de", "German").
            let language = SpeakerTranscriptBuilder.languageCode(from: language)
            let languages = engine.supportedLanguages
            if let language, !languages.isEmpty,
               !languages.contains(where: { language.hasPrefix($0) || $0.hasPrefix(language) }) {
                log.info("Timing pass with Parakeet skipped: Parakeet does not support \(language, privacy: .public)")
                return nil
            }
            let samples = try await audioFileService.loadAudioSamples(from: url)
            return try await modelManagerService.transcribe(
                audioSamples: samples,
                languageSelection: language.map(LanguageSelection.exact) ?? .auto,
                task: .transcribe,
                engineOverrideId: engineID,
                onProgress: { _ in true },
                onSourceProgress: { _ in true }
            )
        }
        speakerCoordinator.timingSource = { [audioFileService, modelManagerService] url, language in
            // Engines such as Qwen3 return text without timestamps; the
            // selected engine would then return none a second time.
            do {
                if let result = try await parakeetTimingPass(url, language), !result.segments.isEmpty {
                    return result
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger(subsystem: AppConstants.loggerSubsystem, category: "SpeakerTranscript")
                    .info("Timing pass with Parakeet failed: \(error.localizedDescription, privacy: .public)")
            }
            let samples = try await audioFileService.loadAudioSamples(from: url)
            return try await modelManagerService.transcribe(
                audioSamples: samples,
                languageSelection: language.map(LanguageSelection.exact) ?? .auto,
                task: .transcribe,
                onProgress: { _ in true },
                onSourceProgress: { _ in true }
            )
        }
        speakerCoordinator.wordTimingSource = { url, language in
            guard let result = try await parakeetTimingPass(url, language) else { return [] }
            // The words are matched to another engine's text, which may
            // punctuate differently.
            return result.words.compactMap { word in
                let text = word.text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                return text.isEmpty ? nil : TranscriptionWord(text: text, start: word.start, end: word.end)
            }
        }
        speakerVoiceProfileService = SpeakerVoiceProfileService(
            store: VoiceProfileStore(),
            historyService: historyService,
            premiumAccess: { [speakerCoordinator] in speakerCoordinator.hasPremiumAccess }
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
        audioRecorderViewModel.addingRecorderSpeakers = { [speakerCoordinator] payload, waits in
            await speakerCoordinator.addingSpeakers(to: payload, waitsForDetection: waits)
        }
        calendarMeetingCountdownModel = CalendarMeetingCountdownModel(
            hotkeyService: hotkeyService,
            onButtonAction: {
                ManagedAppReopenSuppression.shared.markBackgroundInteraction()
            }
        )
        calendarMeetingAutomationController = CalendarMeetingAutomationController(
            licenseService: licenseService,
            premiumAccountService: premiumAccountService,
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
            pluginRegistryService: pluginRegistryService,
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
            ),
            isRemoteWritingAllowed: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.remoteLinkWritingAllowed) }
        ).register(on: router)
        httpServer = HTTPServer(router: router)
        apiServerViewModel = APIServerViewModel(httpServer: httpServer, apiAuthenticator: apiAuthenticator)
        remoteLinkServer = RemoteLinkServer(router: router)
        remoteLinkViewModel = RemoteLinkViewModel(
            server: remoteLinkServer,
            premiumAccess: { [licenseService, premiumAccountService] in
                CalendarMeetingPremiumAccess.isGranted(
                    hasCommercialLicense: licenseService.hasCommercialLicense,
                    hasPremiumEntitlement: premiumAccountService.hasPremiumEntitlement
                )
            }
        )
        remoteLinkViewModel.observePremiumChanges([
            licenseService.objectWillChange.eraseToAnyPublisher(),
            premiumAccountService.objectWillChange.eraseToAnyPublisher(),
        ])
        historyViewModel = HistoryViewModel(
            historyService: historyService,
            textDiffService: textDiffService,
            dictionaryService: dictionaryService,
            syncController: cloudFolderSyncController
        )
        installedAppsViewModel = InstalledAppsViewModel()
        dictionaryViewModel = DictionaryViewModel(
            dictionaryService: dictionaryService,
            licenseService: licenseService,
            termPackRegistryService: termPackRegistryService,
            localTermPackStore: localTermPackStore,
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
        RemoteLinkViewModel._shared = remoteLinkViewModel
        HistoryViewModel._shared = historyViewModel
        DictionaryViewModel._shared = dictionaryViewModel
        SnippetsViewModel._shared = snippetsViewModel
        HomeViewModel._shared = homeViewModel
        StatisticsViewModel._shared = statisticsViewModel
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
        speakerTranscriptionViewModel.observePluginManager()
        dictationRecoveryViewModel.observePluginManager()
        settingsViewModel.observePluginManager()
        audioRecorderViewModel.observePluginManager()
        watchFolderViewModel.observePluginManager()
    }

    /// Applies policy effects that are not evaluated on use: the plugin restrictions, the login item
    /// and, for a changed managed license key, a new activation pass.
    private func applyManagedPolicy(_ snapshot: ManagedPolicySnapshot, previous: ManagedPolicySnapshot?) {
        // Runs before plugins are scanned at launch, so refused plugins never load.
        pluginManager.applyProviderPolicy(ManagedProviderPolicy(snapshot: snapshot))
        pluginManager.applySelectionPolicy(ManagedSelectionPolicy(snapshot: snapshot))
        if previous != nil {
            // At launch these run after the plugins are loaded.
            modelManagerService.restoreProviderSelection()
            promptProcessingService.applyRecommendedLlmPairIfNeeded()
        }
        launchAtLoginController.apply(
            snapshot,
            setupCompleted: UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted)
        )
        #if !APPSTORE
        let key = ManagedPolicyKeys.managedLicenseKey
        if let previous, previous.enforced(key) != snapshot.enforced(key) {
            Task { await licenseService.validateIfNeeded() }
        }
        #endif
    }

    func initialize() async {
        guard !AppConstants.isRunningTests else { return }

        let signposter = LaunchSignposts.signposter
        let initializeState = signposter.beginInterval("Launch.initialize")
        defer { signposter.endInterval("Launch.initialize", initializeState) }

        managedPolicyService.startMonitoring()
        applyManagedPolicy(managedPolicyService.current, previous: nil)
        managedPolicySubscription = managedPolicyService.$current
            .dropFirst()
            .scan((ManagedPolicySnapshot?.none, managedPolicyService.current)) { ($0.1, $1) }
            .sink { [weak self] previous, current in
                self?.applyManagedPolicy(current, previous: previous)
            }

        #if APPSTORE
        // Listen for App Store transactions as early as possible.
        appStorePremiumService.start()
        #endif

        calendarMeetingAutomationController.initialize()
        historyService.failInterruptedSpeakerTranscripts()
        speakerVoiceProfileService.removeEmbeddingsOfDeletedRecordings()

        hotkeyService.setup()
        dictationViewModel.registerInitialTriggerHotkeys()
        usageStatisticsService.backfillFromHistoryIfNeeded {
            try historyService.allRecordsThrowing()
        }
        let retentionDays = UserDefaults.standard.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        if retentionDays > 0 { historyService.purgeOldRecords(retentionDays: retentionDays) }

        if apiServerViewModel.isEnabled {
            apiServerViewModel.startServer()
        }
        remoteLinkViewModel.startIfEnabled()

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

        pluginRegistryService.checkForUpdatesInBackground()

        // Start memory service
        memoryService.startListening()

        #if !APPSTORE
        // Validate license if needed
        await licenseService.validateIfNeeded()
        await licenseService.validateSupporterIfNeeded()
        await supporterDiscordService.refreshStatusIfNeeded()
        #endif

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
