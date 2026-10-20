import Accessibility
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

private final class MockTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    var isActive: Bool = true
    var onFinish: (@Sendable () -> Void)?
    private(set) var stopCallCount = 0
    var onStop: (@Sendable () -> Void)?

    func stop() {
        guard isActive else { return }
        isActive = false
        stopCallCount += 1
        onStop?()
        onFinish?()
    }
}

private final class MockTTSProvider: NSObject, TTSProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.tts"
    static let pluginName = "Mock TTS"

    let providerId: String
    let providerDisplayName: String
    var isConfigured: Bool = true
    var availableVoices: [PluginVoiceInfo] = []
    var selectedVoiceId: String?
    var settingsSummary: String? = "Mock Summary"
    private(set) var requests: [TTSSpeakRequest] = []
    let session = MockTTSPlaybackSession()
    var onSpeak: (@Sendable (TTSSpeakRequest) -> Void)?

    init(providerId: String = "mockTTS", providerDisplayName: String = "Mock TTS") {
        self.providerId = providerId
        self.providerDisplayName = providerDisplayName
    }

    required override init() {
        self.providerId = "mockTTS"
        self.providerDisplayName = "Mock TTS"
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectVoice(_ voiceId: String?) { selectedVoiceId = voiceId }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        requests.append(request)
        session.isActive = true
        onSpeak?(request)
        return session
    }
}

final class SpeechFeedbackServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SpeechFeedbackServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testAutomaticTranscriptionUsesSelectedProvider() async {
        let provider = MockTTSProvider()
        let speakExpectation = expectation(description: "provider speak called")
        provider.onSpeak = { _ in speakExpectation.fulfill() }
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        service.spokenFeedbackEnabled = true
        service.selectedProviderId = provider.providerId
        service.speakAutomaticTranscription(text: "transcribed text", language: "en")
        await fulfillment(of: [speakExpectation], timeout: 1.0)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.purpose, .transcription)
        XCTAssertEqual(provider.requests.first?.text, "transcribed text")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.spokenFeedbackProviderId), provider.providerId)
    }

    @MainActor
    func testReadBackStopsActiveSessionOnSecondInvocation() async {
        let provider = MockTTSProvider()
        let speakExpectation = expectation(description: "provider speak called")
        let stopExpectation = expectation(description: "playback stopped")
        provider.onSpeak = { _ in speakExpectation.fulfill() }
        provider.session.onStop = { stopExpectation.fulfill() }
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        service.readBack(text: "Hello world", language: "en")
        await fulfillment(of: [speakExpectation], timeout: 1.0)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(service.isSpeaking)

        service.readBack(text: "Hello world", language: "en")
        await fulfillment(of: [stopExpectation], timeout: 1.0)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.session.stopCallCount, 1)
        XCTAssertFalse(service.isSpeaking)
    }

    @MainActor
    func testMissingSelectionFallsBackToAvailableProvider() async {
        let provider = MockTTSProvider()
        let speakExpectation = expectation(description: "fallback provider speak called")
        provider.onSpeak = { _ in speakExpectation.fulfill() }
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        service.spokenFeedbackEnabled = true
        service.selectedProviderId = "missing"
        service.speakAutomaticTranscription(text: "transcribed text", language: "en")
        await fulfillment(of: [speakExpectation], timeout: 1.0)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(service.effectiveProviderId, provider.providerId)
        XCTAssertEqual(service.selectedProviderDisplayName, provider.providerDisplayName)
        XCTAssertEqual(service.currentSettingsSummary, provider.settingsSummary)
    }

    @MainActor
    func testAutomaticTranscriptionSkipsVoiceOver() async {
        let provider = MockTTSProvider()
        let service = SpeechFeedbackService(
            defaults: defaults,
            providerResolver: { [provider] in [provider] },
            isVoiceOverEnabled: { true }
        )

        service.spokenFeedbackEnabled = true
        service.speakAutomaticTranscription(text: "transcribed text", language: "en")

        XCTAssertTrue(provider.requests.isEmpty)
    }

    @MainActor
    func testAutomaticTranscriptionSkipsEmptyText() async {
        let provider = MockTTSProvider()
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        service.spokenFeedbackEnabled = true
        service.speakAutomaticTranscription(text: "", language: "en")

        XCTAssertTrue(provider.requests.isEmpty)
    }

    @MainActor
    func testDisableIfNoProvidersAvailableTurnsOffFeedbackAndPersists() async {
        defaults.set(true, forKey: UserDefaultsKeys.spokenFeedbackEnabled)
        let service = SpeechFeedbackService(defaults: defaults) { [] }

        XCTAssertTrue(service.spokenFeedbackEnabled)
        XCTAssertTrue(service.disableIfNoProvidersAvailable())
        XCTAssertFalse(service.spokenFeedbackEnabled)
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled))
    }

    @MainActor
    func testDisableIfNoProvidersAvailableKeepsFeedbackWhenProviderExists() async {
        defaults.set(true, forKey: UserDefaultsKeys.spokenFeedbackEnabled)
        let provider = MockTTSProvider()
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        XCTAssertFalse(service.disableIfNoProvidersAvailable())
        XCTAssertTrue(service.spokenFeedbackEnabled)
    }
}

/// VoiceOver announcements are the spoken counterpart of the indicator banners.
@MainActor
final class AccessibilityAnnouncementServiceTests: XCTestCase {
    private final class Recorder {
        var announcements: [(message: String, isUrgent: Bool)] = []
    }

    private final class TestClock {
        var now = ContinuousClock.now
    }

    private func makeService(
        voiceOverEnabled: Bool = true,
        clock: TestClock = TestClock()
    ) -> (AccessibilityAnnouncementService, Recorder) {
        let recorder = Recorder()
        let service = AccessibilityAnnouncementService()
        service.isVoiceOverEnabled = { voiceOverEnabled }
        service.now = { clock.now }
        service.post = { message, isUrgent in
            recorder.announcements.append((message, isUrgent))
        }
        return (service, recorder)
    }

    func testStaysSilentWithoutVoiceOver() {
        let (service, recorder) = makeService(voiceOverEnabled: false)

        service.announceRecordingStarted()
        service.announceError("Microphone unavailable")

        XCTAssertTrue(recorder.announcements.isEmpty)
    }

    func testSkipsEmptyMessagesAndTrimsWhitespace() {
        let (service, recorder) = makeService()

        service.announce("  \n ")
        service.announce("  Text inserted\n")

        XCTAssertEqual(recorder.announcements.map { $0.message }, ["Text inserted"])
    }

    /// High priority is heard in full; default priority gives way to the next
    /// announcement, so a newer status or palette highlight replaces an older one.
    func testErrorsUseHighPriorityAndOtherAnnouncementsTheReplaceablePriority() {
        XCTAssertEqual(
            AccessibilityAnnouncementService.announcement("Error", isUrgent: true)
                .accessibilitySpeechAnnouncementPriority,
            .high
        )
        XCTAssertEqual(
            AccessibilityAnnouncementService.announcement("Polish Dictation", isUrgent: false)
                .accessibilitySpeechAnnouncementPriority,
            .default
        )
    }

    /// Errors are urgent. Dictation warnings such as the Esc confirmation stay
    /// replaceable, so the "Cancelled" that follows is not held back; time-critical
    /// warnings (countdown, recorder) ask for urgency explicitly.
    func testErrorsAreUrgentAndWarningsOnlyWhenTheyAskForIt() {
        let (service, recorder) = makeService()

        service.announceFeedback("Copied to clipboard", isError: false)
        service.announceFeedback("No speech recognized", isError: true)
        service.announceWarning("Press Esc again to cancel recording")
        service.announceWarning("Meeting recording starts in 10 seconds", isUrgent: true)

        XCTAssertEqual(recorder.announcements.map { $0.isUrgent }, [false, true, false, true])
        XCTAssertEqual(recorder.announcements.first?.message, "Copied to clipboard")
        XCTAssertEqual(
            recorder.announcements.dropFirst().first?.message,
            String(localized: "Error: \("No speech recognized")")
        )
    }

    func testRepeatedMessageWithinTheWindowIsSpokenOnce() {
        let clock = TestClock()
        let (service, recorder) = makeService(clock: clock)

        service.announceError("Please select or copy some text first.")
        clock.now = clock.now.advanced(by: .milliseconds(200))
        service.announceError("Please select or copy some text first.")
        clock.now = clock.now.advanced(by: AccessibilityAnnouncementService.duplicateWindow)
        service.announceError("Please select or copy some text first.")

        XCTAssertEqual(recorder.announcements.count, 2)
    }

    func testDifferentMessagesAreAllSpoken() {
        let (service, recorder) = makeService()

        service.announceRecordingStarted()
        service.announceRecordingStopped()
        service.announceTranscriptionComplete(wordCount: 3)

        XCTAssertEqual(recorder.announcements.count, 3)
    }
}

/// Actions such as copying or exporting show a short confirmation, which VoiceOver hears too.
@MainActor
final class ActionConfirmationTests: XCTestCase {
    private final class Recorder {
        var announcements: [(message: String, isUrgent: Bool)] = []
        var now = ContinuousClock.now
    }

    private func makeAnnouncementService(recorder: Recorder) -> AccessibilityAnnouncementService {
        let service = AccessibilityAnnouncementService()
        service.isVoiceOverEnabled = { true }
        // Far apart, so the duplicate filter does not hide a repeated confirmation.
        service.now = {
            recorder.now = recorder.now.advanced(by: .seconds(5))
            return recorder.now
        }
        service.post = { message, isUrgent in
            recorder.announcements.append((message, isUrgent))
        }
        return service
    }

    func testShowsTheMessageAnnouncesItAndHidesItAfterTheDuration() async throws {
        let recorder = Recorder()
        let confirmation = ActionConfirmation(
            duration: .milliseconds(100),
            announcementService: makeAnnouncementService(recorder: recorder)
        )

        confirmation.show("Copied to clipboard", source: "status")

        XCTAssertEqual(confirmation.message?.text, "Copied to clipboard")
        XCTAssertEqual(confirmation.message?.isError, false)
        XCTAssertEqual(confirmation.message(for: "status")?.text, "Copied to clipboard")
        XCTAssertNil(confirmation.message(for: "models"), "Another row must not show the confirmation")
        XCTAssertEqual(recorder.announcements.map(\.message), ["Copied to clipboard"])
        XCTAssertEqual(recorder.announcements.map(\.isUrgent), [false])

        for _ in 0..<100 where confirmation.message != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(confirmation.message)
    }

    func testANewerMessageReplacesTheOlderOne() async throws {
        let recorder = Recorder()
        let confirmation = ActionConfirmation(
            duration: .milliseconds(100),
            announcementService: makeAnnouncementService(recorder: recorder)
        )

        confirmation.show("Copied to clipboard", source: "status")
        confirmation.show("Copied to clipboard", source: "models")

        XCTAssertEqual(confirmation.message?.source, "models")
        XCTAssertNil(confirmation.message(for: "status"))
        XCTAssertEqual(recorder.announcements.count, 2)

        for _ in 0..<100 where confirmation.message != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(confirmation.message)
    }

    func testErrorsAreUrgentAnnouncements() {
        let recorder = Recorder()
        let confirmation = ActionConfirmation(announcementService: makeAnnouncementService(recorder: recorder))

        confirmation.show("History could not be deleted.", isError: true)

        XCTAssertEqual(confirmation.message?.isError, true)
        XCTAssertEqual(recorder.announcements.map(\.isUrgent), [true])
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            [String(localized: "Error: \("History could not be deleted.")")]
        )
    }
}
