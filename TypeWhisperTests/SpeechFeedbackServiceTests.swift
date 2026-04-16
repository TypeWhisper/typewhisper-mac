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
    func testAnnounceEventUsesSelectedProvider() async {
        let provider = MockTTSProvider()
        let speakExpectation = expectation(description: "provider speak called")
        provider.onSpeak = { _ in speakExpectation.fulfill() }
        let service = SpeechFeedbackService(defaults: defaults) { [provider] in [provider] }

        service.spokenFeedbackEnabled = true
        service.selectedProviderId = provider.providerId
        service.announceEvent(.promptComplete)
        await fulfillment(of: [speakExpectation], timeout: 1.0)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.purpose, .status)
        XCTAssertEqual(provider.requests.first?.text, String(localized: "Prompt complete"))
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
        service.announceEvent(.recordingStarted)
        await fulfillment(of: [speakExpectation], timeout: 1.0)

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(service.effectiveProviderId, provider.providerId)
        XCTAssertEqual(service.selectedProviderDisplayName, provider.providerDisplayName)
        XCTAssertEqual(service.currentSettingsSummary, provider.settingsSummary)
    }
}
