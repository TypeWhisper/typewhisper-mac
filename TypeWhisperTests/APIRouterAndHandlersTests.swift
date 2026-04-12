import AppKit
import CoreAudio
import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class APIRouterAndHandlersTests: XCTestCase {
    @objc(APIRouterMockTranscriptionPlugin)
    private final class MockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.transcription" }
        static var pluginName: String { "Mock Transcription" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "mock" }
        var providerDisplayName: String { "Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterConfigurableTranscriptionPlugin)
    private final class ConfigurableTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.configurable-transcription" }
        static var pluginName: String { "Configurable Mock Transcription" }

        var configured = false
        var currentModelId: String?

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "configurable-mock" }
        var providerDisplayName: String { "Configurable Mock" }
        var isConfigured: Bool { configured }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { currentModelId }
        func selectModel(_ modelId: String) {
            currentModelId = modelId
            configured = true
        }
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    private final class APIContext: @unchecked Sendable {
        let router: APIRouter
        let historyService: HistoryService
        let profileService: ProfileService
        private let retainedObjects: [AnyObject]

        init(router: APIRouter, historyService: HistoryService, profileService: ProfileService, retainedObjects: [AnyObject]) {
            self.router = router
            self.historyService = historyService
            self.profileService = profileService
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private final class MockMediaPlaybackService: MediaPlaybackService {
        let onPause: () -> Void

        init(onPause: @escaping () -> Void) {
            self.onPause = onPause
            super.init(startListening: false)
        }

        override func pauseIfPlaying() {
            onPause()
        }
    }

    #if !APPSTORE
    private final class FakeMediaPlaybackController: MediaPlaybackControlling {
        var returnedSnapshot: (isPlaying: Bool, bundleIdentifier: String?) = (false, nil)
        var onGetPlaybackSnapshot: ((@escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void) -> Void)?
        private(set) var pauseCalls = 0
        private(set) var playCalls = 0

        func getPlaybackSnapshot(_ onReceive: @escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void) {
            if let onGetPlaybackSnapshot {
                onGetPlaybackSnapshot(onReceive)
                return
            }
            onReceive(returnedSnapshot.isPlaying, returnedSnapshot.bundleIdentifier)
        }

        func play() {
            playCalls += 1
        }

        func pause() {
            pauseCalls += 1
        }
    }
    #endif

    func testRouterHandlesOptionsAndNotFound() async {
        let router = APIRouter()

        let optionsResponse = await router.route(
            HTTPRequest(method: "OPTIONS", path: "/v1/status", queryParams: [:], headers: [:], body: Data())
        )
        let notFoundResponse = await router.route(
            HTTPRequest(method: "GET", path: "/missing", queryParams: [:], headers: [:], body: Data())
        )

        XCTAssertEqual(optionsResponse.status, 200)
        XCTAssertEqual(notFoundResponse.status, 404)
    }

    func testAPIHandlersExposeStatusHistoryAndProfiles() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { () -> APIContext in
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory)
            context.historyService.addRecord(
                rawText: "Sprint planning",
                finalText: "Sprint planning",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 5,
                language: "en",
                engineUsed: "parakeet"
            )
            context.profileService.addProfile(
                name: "Docs",
                urlPatterns: ["docs.github.com"],
                priority: 1
            )
            return context
        }

        let router = try XCTUnwrap(context?.router)

        let status = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/status", queryParams: [:], headers: [:], body: Data()))
        )
        let history = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()))
        )
        let profiles = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/profiles", queryParams: [:], headers: [:], body: Data()))
        )

        XCTAssertEqual(status["status"] as? String, "no_model")
        XCTAssertEqual((history["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((profiles["profiles"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
    }

    @MainActor
    func testClipboardSnapshotRoundTripsMultiplePasteboardItems() {
        let firstItem = NSPasteboardItem()
        firstItem.setString("first", forType: .string)
        firstItem.setData(Data([0x01, 0x02]), forType: .png)

        let secondItem = NSPasteboardItem()
        secondItem.setString("second", forType: .string)
        secondItem.setData(Data([0x03, 0x04]), forType: .tiff)

        let snapshot = TextInsertionService.clipboardSnapshot(from: [firstItem, secondItem])
        let restoredItems = TextInsertionService.pasteboardItems(from: snapshot)

        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "first")
        XCTAssertEqual(restoredItems[0].data(forType: .png), Data([0x01, 0x02]))
        XCTAssertEqual(restoredItems[1].string(forType: .string), "second")
        XCTAssertEqual(restoredItems[1].data(forType: .tiff), Data([0x03, 0x04]))
    }

    @MainActor
    func testFocusedTextChangeDetectionRequiresAnActualChange() {
        XCTAssertFalse(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
            )
        )

        XCTAssertTrue(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 11, length: 0))
            )
        )
    }

    @MainActor
    func testAutoEnterSkipsReturnWithoutFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { false }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertFalse(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testAutoEnterTriggersReturnWithFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { true }
        service.pasteSimulatorOverride = {}

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testApiStartRecording_startsAudioBeforeDeferredSelectedTextCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)

        var events: [String] = []
        let selectedTextCaptured = expectation(description: "selected text captured")

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Notes", nil, nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }
        context.textInsertionService.selectedTextOverride = { () -> String? in
            events.append("selected_text")
            selectedTextCaptured.fulfill()
            return "Already selected"
        }

        context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(events, ["capture_app", "start_audio"])

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
        XCTAssertEqual(Array(events.prefix(3)), ["capture_app", "start_audio", "selected_text"])
    }

    @MainActor
    func testApiStartRecording_appliesBundleProfileBeforeDeferredMetadataCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.profileService.addProfile(name: "Docs", bundleIdentifiers: ["com.typewhisper.tests"])

        let selectedTextCaptured = expectation(description: "selected text captured")
        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            ("Docs App", "com.typewhisper.tests", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.textInsertionService.selectedTextOverride = { () -> String? in
            selectedTextCaptured.fulfill()
            return nil
        }

        context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(context.dictationViewModel.activeProfileName, "Docs")

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
    }

    @MainActor
    func testApiStartRecording_pausesMediaAfterAudioStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let mediaPlaybackService = MockMediaPlaybackService {
            events.append("pause_media")
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.mediaPauseEnabled = true

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Music", "com.apple.Music", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(Array(events.prefix(3)), ["capture_app", "start_audio", "pause_media"])
    }

    #if !APPSTORE
    @MainActor
    func testMediaPlaybackServicePausesAndResumesFromOneShotTrackInfo() {
        let controller = FakeMediaPlaybackController()
        controller.returnedSnapshot = (true, "com.apple.Music")
        let service = MediaPlaybackService(startListening: false) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseWhenPlaybackIsAlreadyStopped() {
        let controller = FakeMediaPlaybackController()
        controller.returnedSnapshot = (false, nil)
        let service = MediaPlaybackService(startListening: false) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceIgnoresStalePauseProbeAfterResume() {
        let controller = FakeMediaPlaybackController()
        var deferredCallback: ((_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void)?
        controller.onGetPlaybackSnapshot = { callback in
            deferredCallback = callback
        }
        let service = MediaPlaybackService(startListening: false) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        deferredCallback?(true, "com.apple.Music")

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }
    #endif

    @MainActor
    func testApiStartRecording_showsSelectModelErrorWhenNoProviderIsSelected() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
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

        let dictationViewModel = DictationViewModel(
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
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false

        dictationViewModel.apiStartRecording()

        XCTAssertEqual(dictationViewModel.state, .inserting)
        XCTAssertEqual(
            dictationViewModel.actionFeedbackMessage,
            TranscriptionEngineError.modelNotLoaded.localizedDescription
        )
    }

    @MainActor
    func testApiStartRecording_showsNoMicDetectedErrorWhenNoInputAvailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in false }

        context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(context.dictationViewModel.actionFeedbackMessage, "No mic detected.")
    }

    @MainActor
    func testApiStartRecording_preservesPermissionDeniedError() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.hasMicrophonePermissionOverride = false

        context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            "Microphone permission required."
        )
    }

    @MainActor
    func testModelManagerAutoSelectsConfiguredEngineAfterPluginCapabilityChange() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.observePluginManager()
        XCTAssertNil(modelManager.selectedProviderId)

        plugin.currentModelId = "tiny"
        plugin.configured = true
        PluginManager.shared.notifyPluginStateChanged()

        let propagation = expectation(description: "plugin capability propagation")
        DispatchQueue.main.async {
            propagation.fulfill()
        }
        await fulfillment(of: [propagation], timeout: 1.0)

        XCTAssertEqual(modelManager.selectedProviderId, plugin.providerId)
    }

    @MainActor
    private static func makeAPIContext(appSupportDirectory: URL) -> APIContext {
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let modelManager = ModelManagerService()
        let audioFileService = AudioFileService()
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

        let dictationViewModel = DictationViewModel(
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
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )

        let router = APIRouter()
        let handlers = APIHandlers(
            modelManager: modelManager,
            audioFileService: audioFileService,
            translationService: nil,
            historyService: historyService,
            profileService: profileService,
            dictationViewModel: dictationViewModel
        )
        handlers.register(on: router)

        return APIContext(
            router: router,
            historyService: historyService,
            profileService: profileService,
            retainedObjects: [
                PluginManager.shared,
                modelManager,
                audioFileService,
                audioRecordingService,
                hotkeyService,
                textInsertionService,
                historyService,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                dictationViewModel,
                router,
                handlers
            ]
        )
    }

    private final class DictationContext: @unchecked Sendable {
        let dictationViewModel: DictationViewModel
        let audioRecordingService: AudioRecordingService
        let textInsertionService: TextInsertionService
        let profileService: ProfileService
        private let retainedObjects: [AnyObject]

        init(
            dictationViewModel: DictationViewModel,
            audioRecordingService: AudioRecordingService,
            textInsertionService: TextInsertionService,
            profileService: ProfileService,
            retainedObjects: [AnyObject]
        ) {
            self.dictationViewModel = dictationViewModel
            self.audioRecordingService = audioRecordingService
            self.textInsertionService = textInsertionService
            self.profileService = profileService
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private static func makeDictationContext(
        appSupportDirectory: URL,
        mediaPlaybackService: MediaPlaybackService? = nil
    ) -> DictationContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let mockPlugin = MockTranscriptionPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: mockPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(mockPlugin.providerId)

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
        let mediaPlaybackService = mediaPlaybackService ?? MediaPlaybackService(startListening: false)

        let dictationViewModel = DictationViewModel(
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
            mediaPlaybackService: mediaPlaybackService
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false
        dictationViewModel.audioDuckingEnabled = false
        dictationViewModel.mediaPauseEnabled = false

        return DictationContext(
            dictationViewModel: dictationViewModel,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            profileService: profileService,
            retainedObjects: [
                EventBus.shared,
                PluginManager.shared,
                modelManager,
                audioRecordingService,
                hotkeyService,
                textInsertionService,
                historyService,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                mediaPlaybackService,
                dictationViewModel
            ]
        )
    }

    private static func jsonObject(_ response: HTTPResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.body)
        return try XCTUnwrap(object as? [String: Any])
    }
}

final class AudioRecordingServiceInputAvailabilityTests: XCTestCase {
    func testStartRecording_throwsNoMicrophoneDetectedBeforeStartingOverride() {
        let service = AudioRecordingService()
        var didReachStartOverride = false

        service.hasMicrophonePermissionOverride = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return false
        }
        service.startRecordingOverride = {
            didReachStartOverride = true
        }

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.noMicrophoneDetected = error else {
                return XCTFail("Expected noMicrophoneDetected, got \(error)")
            }
        }
        XCTAssertFalse(didReachStartOverride)
    }
}

final class HotkeyServiceCompatibilityTests: XCTestCase {
    @MainActor
    func testMonitorFallbackStartsToggleHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testEventTapDispatchDedupesFollowingMonitorDispatch() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMonitorFallbackStopsPushToTalkOnKeyUp() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = {
            startCount += 1
        }
        service.onDictationStop = {
            stopCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    private func spaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue,
            isFn: false
        )
    }

    private func makeKeyboardEvent(keyCode: UInt16, keyDown: Bool) throws -> NSEvent {
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        )
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}
