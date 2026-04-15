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

        var languages: [String] = []

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
        var supportedLanguages: [String] { languages }

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
        let dictationViewModel: DictationViewModel
        let audioRecordingService: AudioRecordingService
        let textInsertionService: TextInsertionService
        private let retainedObjects: [AnyObject]

        init(
            router: APIRouter,
            historyService: HistoryService,
            profileService: ProfileService,
            dictationViewModel: DictationViewModel,
            audioRecordingService: AudioRecordingService,
            textInsertionService: TextInsertionService,
            retainedObjects: [AnyObject]
        ) {
            self.router = router
            self.historyService = historyService
            self.profileService = profileService
            self.dictationViewModel = dictationViewModel
            self.audioRecordingService = audioRecordingService
            self.textInsertionService = textInsertionService
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

    func testAPIHandlersExposeStatusHistoryAndRules() async throws {
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
        let rules = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/rules", queryParams: [:], headers: [:], body: Data()))
        )
        let legacyProfiles = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/profiles", queryParams: [:], headers: [:], body: Data()))
        )

        XCTAssertEqual(status["status"] as? String, "no_model")
        XCTAssertEqual((history["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
        XCTAssertEqual((legacyProfiles["profiles"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
    }

    func testDictationStartReturnsConflictWhenRecordingCannotStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, TranscriptionEngineError.modelNotLoaded.localizedDescription)
    }

    func testDictationEndpointsReturnSessionIDAndCompletedTranscription() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        await MainActor.run {
            apiContext.audioRecordingService.hasMicrophonePermissionOverride = true
            apiContext.audioRecordingService.inputAvailabilityOverride = { _ in true }
            apiContext.audioRecordingService.startRecordingOverride = {}
            apiContext.audioRecordingService.stopRecordingOverride = { _ in
                Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
            }
            apiContext.textInsertionService.accessibilityGrantedOverride = true
            apiContext.textInsertionService.captureActiveAppOverride = {
                ("Notes", "com.apple.Notes", nil)
            }
            apiContext.textInsertionService.selectedTextOverride = { nil }
            apiContext.textInsertionService.pasteSimulatorOverride = {}
        }

        let start = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data()))
        )
        let startID = try XCTUnwrap(start["id"] as? String)
        XCTAssertEqual(start["status"] as? String, "recording")
        XCTAssertNotNil(UUID(uuidString: startID))

        await MainActor.run {
            apiContext.dictationViewModel.partialText = "transcribed"
        }

        let stop = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data()))
        )
        XCTAssertEqual(stop["id"] as? String, startID)
        XCTAssertEqual(stop["status"] as? String, "stopped")

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/dictation/transcription",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let completedPayload = try XCTUnwrap(completedResponse)
        XCTAssertEqual(completedPayload["id"] as? String, startID)
        XCTAssertEqual(completedPayload["status"] as? String, "completed")

        let transcription = try XCTUnwrap(completedPayload["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["text"] as? String, "transcribed")
        XCTAssertEqual(transcription["raw_text"] as? String, "transcribed")
        XCTAssertEqual(transcription["app_name"] as? String, "Notes")
        XCTAssertEqual(transcription["app_bundle_id"] as? String, "com.apple.Notes")
        XCTAssertEqual(transcription["words_count"] as? Int, 1)

        let recordID = await MainActor.run { apiContext.historyService.records.first?.id.uuidString }
        XCTAssertEqual(recordID, startID)
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
    func testPreserveClipboardAvoidsPasteboardWhenVerifiedAccessibilityInsertionSucceeds() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }

        var stateReadCount = 0
        service.focusedTextStateOverride = { _ in
            defer { stateReadCount += 1 }
            if stateReadCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertEqual(insertedText, "Hello")
        XCTAssertFalse(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testPreserveClipboardFallsBackToPasteboardWhenVerifiedAccessibilityInsertionFails() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.focusedTextStateOverride = { _ in
            (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }
        service.insertTextAtOverride = { _, _ in true }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
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

        _ = context.dictationViewModel.apiStartRecording()

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

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(context.dictationViewModel.activeRuleName, "Docs")

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

        _ = context.dictationViewModel.apiStartRecording()

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

        _ = dictationViewModel.apiStartRecording()

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

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "No mic detected.")
        )
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

        _ = context.dictationViewModel.apiStartRecording()

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
    func testTranslationTargetLanguagesKeepScriptVariantsDistinct() {
        guard #available(macOS 15.0, *) else { return }

        let namesByCode = Dictionary(uniqueKeysWithValues: TranslationService.availableTargetLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
    }

    func testLocalizedAppLanguageNameKeepsScriptVariantsDistinct() {
        XCTAssertNotEqual(localizedAppLanguageName(for: "zh-Hans"), localizedAppLanguageName(for: "zh-Hant"))
    }

    @MainActor
    func testSettingsViewModelAvailableLanguagesKeepsRegionalAndScriptVariantsDistinct() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockTranscriptionPlugin()
        plugin.languages = ["zh-Hans", "zh-Hant", "pt-BR", "pt-PT"]
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
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

        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let namesByCode = Dictionary(uniqueKeysWithValues: settingsViewModel.availableLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
        XCTAssertNotEqual(namesByCode["pt-BR"], namesByCode["pt-PT"])
    }

    @MainActor
    private static func makeAPIContext(appSupportDirectory: URL, withMockTranscriptionPlugin: Bool = false) -> APIContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let modelManager = ModelManagerService()
        if withMockTranscriptionPlugin {
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
            modelManager.selectProvider(mockPlugin.providerId)
        }
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
            dictationViewModel: dictationViewModel,
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
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
    func testCapsLockOriginSuppressesModifierComboHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testCapsLockOriginSuppressesKeyWithModifiersHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
        let keyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [.maskCommand, .maskAlternate])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testModifierComboStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertTrue(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testKeyWithModifiersStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testBareKeyHotkeyRemainsAllowedAfterCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(bareSpaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testLegacyModifierComboHotkeyMatchesBothSides() throws {
        let rightComboEvent = try makeFlagsChangedEvent(
            keyCode: 0x3D,
            modifierFlags: modifierFlags([.command, .option], deviceFlags: rightCommandRightOptionDeviceFlags())
        )
        let leftComboEvent = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: modifierFlags([.command, .option], deviceFlags: leftCommandLeftOptionDeviceFlags())
        )

        let rightService = HotkeyService()
        rightService.suspendMonitoring()
        rightService.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var rightStartCount = 0
        rightService.onDictationStart = {
            rightStartCount += 1
        }

        XCTAssertTrue(rightService.processEventForTesting(rightComboEvent, source: .monitor))
        XCTAssertEqual(rightStartCount, 1)

        let leftService = HotkeyService()
        leftService.suspendMonitoring()
        leftService.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var leftStartCount = 0
        leftService.onDictationStart = {
            leftStartCount += 1
        }

        XCTAssertTrue(leftService.processEventForTesting(leftComboEvent, source: .monitor))
        XCTAssertEqual(leftStartCount, 1)
    }

    @MainActor
    func testRightSpecificModifierComboHotkeyRejectsLeftSide() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(rightCommandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let leftComboEvent = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: modifierFlags([.command, .option], deviceFlags: leftCommandLeftOptionDeviceFlags())
        )
        let rightComboEvent = try makeFlagsChangedEvent(
            keyCode: 0x3D,
            modifierFlags: modifierFlags([.command, .option], deviceFlags: rightCommandRightOptionDeviceFlags())
        )

        XCTAssertFalse(service.processEventForTesting(leftComboEvent, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(rightComboEvent, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testRightSpecificKeyWithModifiersHotkeyRejectsLeftCommand() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(rightCommandAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = {
            startCount += 1
        }

        let leftCommandKeyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: keyboardFlags([.maskCommand], deviceFlags: leftCommandDeviceFlag)
        )
        let rightCommandKeyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: keyboardFlags([.maskCommand], deviceFlags: rightCommandDeviceFlag)
        )

        XCTAssertFalse(service.processEventForTesting(leftCommandKeyDown, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(rightCommandKeyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testRightSpecificKeyWithModifiersStopsWhenMatchingSideChanges() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(rightCommandAHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = {
            startCount += 1
        }
        service.onDictationStop = {
            stopCount += 1
        }

        let keyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: keyboardFlags([.maskCommand], deviceFlags: rightCommandDeviceFlag)
        )
        let switchedSideEvent = try makeFlagsChangedEvent(
            keyCode: 0x37,
            modifierFlags: modifierFlags([.command], deviceFlags: leftCommandDeviceFlag)
        )

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(switchedSideEvent, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testGenericAndSpecificHotkeysConflictButOppositeSidesDoNot() {
        let genericService = HotkeyService()
        genericService.suspendMonitoring()
        genericService.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)
        XCTAssertEqual(genericService.isHotkeyAssigned(rightCommandOptionComboHotkey(), excluding: .hybrid), .toggle)

        let specificService = HotkeyService()
        specificService.suspendMonitoring()
        specificService.setHotkeyForTesting(leftCommandOptionComboHotkey(), for: .toggle)
        XCTAssertNil(specificService.isHotkeyAssigned(rightCommandOptionComboHotkey(), excluding: .hybrid))
    }

    @MainActor
    func testProfileConflictUsesSameSideAwareOverlapRules() {
        let service = HotkeyService()
        service.suspendMonitoring()

        let genericProfileId = UUID()
        service.registerProfileHotkeys([(id: genericProfileId, hotkey: commandOptionComboHotkey())])
        XCTAssertEqual(service.isHotkeyAssignedToProfile(rightCommandOptionComboHotkey(), excludingProfileId: nil), genericProfileId)

        let leftSpecificProfileId = UUID()
        service.registerProfileHotkeys([(id: leftSpecificProfileId, hotkey: leftCommandOptionComboHotkey())])
        XCTAssertNil(service.isHotkeyAssignedToProfile(rightCommandOptionComboHotkey(), excludingProfileId: nil))
    }

    func testUnifiedHotkeyDecodesLegacyPayloadWithoutDeviceModifierFlags() throws {
        let legacyPayload = """
        {"keyCode":\(UnifiedHotkey.modifierComboKeyCode),"modifierFlags":\(NSEvent.ModifierFlags([.command,.option]).rawValue),"isFn":false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(UnifiedHotkey.self, from: legacyPayload)

        XCTAssertEqual(decoded.keyCode, UnifiedHotkey.modifierComboKeyCode)
        XCTAssertEqual(decoded.modifierFlags, NSEvent.ModifierFlags([.command, .option]).rawValue)
        XCTAssertEqual(decoded.deviceModifierFlags, 0)
        XCTAssertFalse(decoded.isDoubleTap)
    }

    @MainActor
    func testUnifiedHotkeyRoundTripsDeviceModifierFlags() throws {
        let hotkey = rightCommandOptionComboHotkey()

        let encoded = try JSONEncoder().encode(hotkey)
        let decoded = try JSONDecoder().decode(UnifiedHotkey.self, from: encoded)

        XCTAssertEqual(decoded, hotkey)
        XCTAssertEqual(decoded.deviceModifierFlags, rightCommandRightOptionDeviceFlags())
    }

    @MainActor
    func testDisplayNameShowsSpecificModifierSides() {
        XCTAssertEqual(HotkeyService.displayName(for: rightCommandOptionComboHotkey()), "R⌥R⌘")
        XCTAssertEqual(HotkeyService.displayName(for: rightCommandAHotkey()), "R⌘A")
        XCTAssertEqual(
            HotkeyService.displayName(for: UnifiedHotkey(keyCode: 0x36, modifierFlags: 0, isFn: false)),
            "R⌘"
        )
    }

    @MainActor
    private func spaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func commandOptionComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func leftCommandOptionComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            deviceModifierFlags: leftCommandLeftOptionDeviceFlags(),
            isFn: false
        )
    }

    @MainActor
    private func rightCommandOptionComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            deviceModifierFlags: rightCommandRightOptionDeviceFlags(),
            isFn: false
        )
    }

    @MainActor
    private func commandOptionAHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func rightCommandAHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags([.command]).rawValue,
            deviceModifierFlags: rightCommandDeviceFlag,
            isFn: false
        )
    }

    @MainActor
    private func bareSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: 0,
            isFn: false
        )
    }

    private func makeKeyboardEvent(
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        )
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func makeFlagsChangedEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func modifierFlags(_ flags: NSEvent.ModifierFlags, deviceFlags: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: flags.rawValue | deviceFlags)
    }

    private func keyboardFlags(_ flags: CGEventFlags, deviceFlags: UInt) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue | UInt64(deviceFlags))
    }

    private func leftCommandLeftOptionDeviceFlags() -> UInt {
        leftCommandDeviceFlag | leftOptionDeviceFlag
    }

    private func rightCommandRightOptionDeviceFlags() -> UInt {
        rightCommandDeviceFlag | rightOptionDeviceFlag
    }

    private let leftCommandDeviceFlag: UInt = 0x00000008
    private let rightCommandDeviceFlag: UInt = 0x00000010
    private let leftOptionDeviceFlag: UInt = 0x00000020
    private let rightOptionDeviceFlag: UInt = 0x00000040
}
