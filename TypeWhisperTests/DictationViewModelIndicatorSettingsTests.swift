import XCTest
@testable import TypeWhisper

final class DictationViewModelIndicatorSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)
        super.tearDown()
    }

    @MainActor
    func testIndicatorTranscriptPreviewDefaultsToEnabled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "DictationIndicatorDefault")
        defer { TestSupport.remove(appSupportDirectory) }

        let viewModel = Self.makeDictationViewModel(appSupportDirectory: appSupportDirectory)

        XCTAssertTrue(viewModel.indicatorTranscriptPreviewEnabled)
    }

    @MainActor
    func testIndicatorTranscriptPreviewPersistsWhenDisabled() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "DictationIndicatorPersist")
        defer { TestSupport.remove(appSupportDirectory) }

        let viewModel = Self.makeDictationViewModel(appSupportDirectory: appSupportDirectory)
        viewModel.indicatorTranscriptPreviewEnabled = false

        XCTAssertEqual(
            UserDefaults.standard.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool,
            false
        )

        let reloadedViewModel = Self.makeDictationViewModel(appSupportDirectory: appSupportDirectory)
        XCTAssertFalse(reloadedViewModel.indicatorTranscriptPreviewEnabled)
    }

    @MainActor
    func testMissingIndicatorTranscriptPreviewKeyFallsBackToTrue() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "DictationIndicatorFallback")
        defer { TestSupport.remove(appSupportDirectory) }

        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)

        let viewModel = Self.makeDictationViewModel(appSupportDirectory: appSupportDirectory)

        XCTAssertTrue(viewModel.indicatorTranscriptPreviewEnabled)
    }

    @MainActor
    private static func makeDictationViewModel(appSupportDirectory: URL) -> DictationViewModel {
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let modelManager = ModelManagerService()
        let audioRecordingService = AudioRecordingService()
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let audioDeviceService = AudioDeviceService()
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)

        return DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            profileService: profileService,
            translationService: nil,
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
            errorLogService: errorLogService,
            mediaPlaybackService: MediaPlaybackService()
        )
    }
}
