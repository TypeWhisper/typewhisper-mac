import XCTest
@testable import TypeWhisper

/// Scripted speech and silence for the silence stop of toggle dictations (#1023). Levels are
/// constant RMS values per stretch; time is audio time at 16 kHz.
private enum ScriptedAudio {
    static let speechLevel: Float = 0.05
    /// Below the speech floor of 0.004, like a quiet room.
    static let roomNoiseLevel: Float = 0.002
    /// Above the speech floor, like a fan close to the microphone.
    static let loudNoiseLevel: Float = 0.01

    static func samples(seconds: TimeInterval, level: Float) -> [Float] {
        let count = Int((seconds * AudioRecordingService.targetSampleRate).rounded())
        // Alternating signs keep the RMS at `level` without a DC offset.
        return (0..<count).map { $0.isMultiple(of: 2) ? level : -level }
    }

    static func speech(_ seconds: TimeInterval) -> [Float] { samples(seconds: seconds, level: speechLevel) }
    static func silence(_ seconds: TimeInterval) -> [Float] { samples(seconds: seconds, level: 0) }
}

final class DictationSilenceDurationInputTests: XCTestCase {
    func testFilterKeepsDigitsAndOneDecimalPlace() {
        XCTAssertEqual(DictationSilenceDurationInput.filtered("4.5"), "4.5")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("4,5"), "4,5")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("4a s"), "4")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("4.55"), "4.5")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("4.5.1"), "4.5")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("123"), "12")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("-3"), "3")
        XCTAssertEqual(DictationSilenceDurationInput.filtered("٣"), "", "only ASCII digits")
    }

    func testDurationRoundsToTenthsAndClampsToTheRange() {
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: "4,5"), 4.5)
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: "2.5"), 2.5)
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: "7"), 7)
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: "0.2"), 1)
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: "25"), 10)
        XCTAssertEqual(DictationSilenceDurationInput.duration(from: ",5"), 1)
    }

    func testTextWithoutANumberKeepsTheSavedValue() {
        XCTAssertNil(DictationSilenceDurationInput.duration(from: ""))
        XCTAssertNil(DictationSilenceDurationInput.duration(from: "."))
    }

    func testTextUsesTheAppLanguageSeparator() {
        XCTAssertEqual(DictationSilenceDurationInput.text(for: 4.5, locale: Locale(identifier: "de")), "4,5")
        XCTAssertEqual(DictationSilenceDurationInput.text(for: 4.5, locale: Locale(identifier: "en")), "4.5")
        XCTAssertEqual(DictationSilenceDurationInput.text(for: 3, locale: Locale(identifier: "en")), "3")
    }
}

final class DictationSilenceEndpointDetectorTests: XCTestCase {
    func testSpeechThenSustainedSilenceReachesTheEndpoint() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 3)

        XCTAssertEqual(detector.append(ScriptedAudio.speech(1)), .listening)
        XCTAssertNotEqual(detector.append(ScriptedAudio.silence(2.9)), .endpointReached)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(0.1)), .endpointReached)
    }

    func testSilenceBeforeSpeechNeverReachesTheEndpoint() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)

        XCTAssertEqual(detector.append(ScriptedAudio.silence(30)), .waitingForSpeech)
        XCTAssertEqual(
            detector.append(ScriptedAudio.samples(seconds: 30, level: ScriptedAudio.roomNoiseLevel)),
            .waitingForSpeech
        )
    }

    func testPauseShorterThanTheDurationDoesNotStopAndSpeechRestartsTheWindow() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 3)

        detector.append(ScriptedAudio.speech(1))
        XCTAssertNotEqual(detector.append(ScriptedAudio.silence(2.5)), .endpointReached)
        XCTAssertEqual(detector.append(ScriptedAudio.speech(0.5)), .listening)
        XCTAssertNotEqual(detector.append(ScriptedAudio.silence(2.9)), .endpointReached)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(0.1)), .endpointReached)
    }

    func testShortNoiseAtTheStartDoesNotArmTheStop() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)

        // A key click or the start sound: two loud frames, then silence.
        XCTAssertEqual(detector.append(ScriptedAudio.speech(0.2)), .waitingForSpeech)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(10)), .waitingForSpeech)
    }

    func testSeparateNoiseBurstsDoNotAddUpToSpeech() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 3)

        // Three 100 ms bursts (a start sound, a key click, a cough) spread over seconds
        // reach the minimum speech duration only when added up.
        for _ in 0..<3 {
            XCTAssertEqual(detector.append(ScriptedAudio.speech(0.1)), .waitingForSpeech)
            XCTAssertEqual(detector.append(ScriptedAudio.silence(1)), .waitingForSpeech)
        }
        XCTAssertEqual(detector.append(ScriptedAudio.silence(10)), .waitingForSpeech)

        // Continuous speech still arms the stop.
        XCTAssertEqual(detector.append(ScriptedAudio.speech(0.3)), .listening)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(3)), .endpointReached)
    }

    func testQuietRoomNoiseCountsAsSilence() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 2)

        detector.append(ScriptedAudio.speech(1))
        let roomNoise = ScriptedAudio.samples(seconds: 2, level: ScriptedAudio.roomNoiseLevel)

        XCTAssertEqual(detector.append(roomNoise), .endpointReached)
    }

    func testSteadyNoiseAboveTheSpeechFloorKeepsRecording() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)

        detector.append(ScriptedAudio.speech(1))
        let fan = ScriptedAudio.samples(seconds: 30, level: ScriptedAudio.loudNoiseLevel)

        XCTAssertEqual(detector.append(fan), .listening)
    }

    func testANoiseBurstDuringTheSilenceRestartsTheWindow() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 2)

        detector.append(ScriptedAudio.speech(1))
        detector.append(ScriptedAudio.silence(1.5))
        detector.append(ScriptedAudio.speech(0.1))

        XCTAssertNotEqual(detector.append(ScriptedAudio.silence(1.9)), .endpointReached)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(0.1)), .endpointReached)
    }

    func testCountdownCoversTheLastTwoSecondsOfLongerDurations() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 5)
        detector.append(ScriptedAudio.speech(1))

        XCTAssertEqual(detector.append(ScriptedAudio.silence(2.9)), .listening)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(0.1)), .stopping(remaining: 2))
        XCTAssertEqual(detector.append(ScriptedAudio.silence(1.5)), .stopping(remaining: 0.5))
    }

    func testShorterDurationsCountDownForHalfTheWindow() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 3)
        detector.append(ScriptedAudio.speech(1))
        XCTAssertEqual(detector.append(ScriptedAudio.silence(1.4)), .listening)
        XCTAssertEqual(detector.append(ScriptedAudio.silence(0.1)), .stopping(remaining: 1.5))

        var shortest = DictationSilenceEndpointDetector(silenceDuration: 1)
        shortest.append(ScriptedAudio.speech(1))
        XCTAssertEqual(shortest.append(ScriptedAudio.silence(0.4)), .listening)
        XCTAssertEqual(shortest.append(ScriptedAudio.silence(0.1)), .stopping(remaining: 0.5))
    }

    func testCountdownSecondsRoundUp() {
        XCTAssertEqual(DictationSilenceEndpointDetector.countdownSeconds(for: 2), 2)
        XCTAssertEqual(DictationSilenceEndpointDetector.countdownSeconds(for: 1.9), 2)
        XCTAssertEqual(DictationSilenceEndpointDetector.countdownSeconds(for: 1.0000000000000002), 1)
        XCTAssertEqual(DictationSilenceEndpointDetector.countdownSeconds(for: 0.1), 1)
    }

    func testFramesSplitAcrossDeliveriesAreJudgedWhole() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)
        let recording = ScriptedAudio.speech(0.5) + ScriptedAudio.silence(1)
        var phases: [DictationSilenceEndpointDetector.Phase] = []

        // Deliveries of 1 000 samples do not line up with the 1 600-sample frames.
        var offset = 0
        while offset < recording.count {
            let end = min(offset + 1_000, recording.count)
            phases.append(detector.append(Array(recording[offset..<end])))
            offset = end
        }

        XCTAssertEqual(phases.last, .endpointReached)
        XCTAssertEqual(phases.filter { $0 == .endpointReached }.count, 1)
    }

    func testStalledInputDoesNotCountAsSilence() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)
        detector.append(ScriptedAudio.speech(1))

        for _ in 0..<100 {
            XCTAssertEqual(detector.append([]), .listening)
        }
    }

    func testEndpointIsFinal() {
        var detector = DictationSilenceEndpointDetector(silenceDuration: 1)
        detector.append(ScriptedAudio.speech(1) + ScriptedAudio.silence(1) + ScriptedAudio.speech(1))

        XCTAssertEqual(detector.phase, .endpointReached)
        XCTAssertEqual(detector.append(ScriptedAudio.speech(1)), .endpointReached)
    }

    func testSilenceDurationIsClampedToTheOfferedRange() {
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(nil), 3)
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(.nan), 3)
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(.infinity), 3)
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(0.2), 1)
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(60), 10)
        XCTAssertEqual(DictationSilenceEndpointDetector.clampedSilenceDuration(2.5), 2.5)
        XCTAssertEqual(DictationSilenceEndpointDetector(silenceDuration: 0).silenceDuration, 1)
    }

    func testSilenceStopSettingsDefaultToOffAndClampStoredDurations() throws {
        let suiteName = "DictationSilenceEndpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(DictationViewModel.loadToggleSilenceStopEnabled(defaults: defaults))
        XCTAssertEqual(DictationViewModel.loadToggleSilenceStopDuration(defaults: defaults), 3)

        DictationViewModel.persistToggleSilenceStopEnabled(true, defaults: defaults)
        DictationViewModel.persistToggleSilenceStopDuration(4.5, defaults: defaults)
        XCTAssertTrue(DictationViewModel.loadToggleSilenceStopEnabled(defaults: defaults))
        XCTAssertEqual(DictationViewModel.loadToggleSilenceStopDuration(defaults: defaults), 4.5)

        defaults.set(120, forKey: UserDefaultsKeys.toggleDictationSilenceStopDuration)
        XCTAssertEqual(DictationViewModel.loadToggleSilenceStopDuration(defaults: defaults), 10)
        defaults.set("soon", forKey: UserDefaultsKeys.toggleDictationSilenceStopDuration)
        XCTAssertEqual(DictationViewModel.loadToggleSilenceStopDuration(defaults: defaults), 3)
    }

    func testDurationsAreSpelledOutWithTheirUnit() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(DictationViewModel.formattedSilenceDuration(1, locale: english), "1 second")
        XCTAssertEqual(DictationViewModel.formattedSilenceDuration(2.5, locale: english), "2.5 seconds")
        XCTAssertEqual(DictationViewModel.formattedSilenceDuration(3, locale: english), "3 seconds")
        XCTAssertEqual(
            DictationViewModel.formattedSilenceDuration(2.5, locale: Locale(identifier: "de")),
            "2,5 Sekunden"
        )
    }
}

/// A recording buffer the tests append to, read like `AudioRecordingService.getBufferDelta`.
@MainActor
private final class ScriptedRecording {
    private(set) var samples: [Float] = []

    func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    /// A new recording starts with an empty buffer.
    func reset() {
        samples.removeAll()
    }

    func delta(since offset: Int) -> (samples: [Float], nextOffset: Int) {
        let clampedOffset = max(0, min(offset, samples.count))
        return (Array(samples[clampedOffset...]), samples.count)
    }
}

/// Poll clock the tests advance by hand: every sleep waits until `fireNext()`.
@MainActor
private final class ManualPollClock {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    var pendingSleepCount: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Ends the earliest pending sleep, as if its interval elapsed.
    func fireNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// Ends every pending sleep with an error, so no poll task stays suspended after a test.
    func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// Monitor with a scripted recording and a hand-advanced poll clock.
@MainActor
private final class MonitorHarness {
    let recording = ScriptedRecording()
    let clock = ManualPollClock()
    let monitor: DictationSilenceEndpointMonitor
    private(set) var endpoints: [UUID] = []
    private(set) var phases: [(sessionID: UUID, phase: DictationSilenceEndpointDetector.Phase)] = []

    init() {
        let recording = recording
        let clock = clock
        monitor = DictationSilenceEndpointMonitor(
            pollInterval: .milliseconds(100),
            sleep: { duration in try await clock.sleep(duration) },
            readSamples: { offset in recording.delta(since: offset) }
        )
        monitor.onEndpoint = { [weak self] sessionID in
            self?.endpoints.append(sessionID)
        }
        monitor.onPhaseChange = { [weak self] sessionID, phase in
            self?.phases.append((sessionID, phase))
        }
    }

    func tearDown() {
        monitor.stop()
        clock.cancelAll()
    }

    func waitForPendingSleep(count: Int = 1) async throws {
        try await waitUntil { self.clock.pendingSleepCount >= count }
    }

    /// Lets main-actor tasks run, without a wall-clock timeout.
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not reached")
    }

    func yieldRepeatedly() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}

@MainActor
final class DictationSilenceEndpointMonitorTests: XCTestCase {
    func testPollTimerReportsTheEndpointOnceAndStops() async throws {
        let harness = MonitorHarness()
        defer { harness.tearDown() }
        let sessionID = UUID()
        harness.monitor.start(sessionID: sessionID, silenceDuration: 1)
        harness.recording.append(ScriptedAudio.speech(0.5) + ScriptedAudio.silence(1))

        try await harness.waitForPendingSleep()
        harness.clock.fireNext()
        try await harness.waitUntil { harness.endpoints.count == 1 }

        XCTAssertEqual(harness.endpoints, [sessionID])
        XCTAssertNil(harness.monitor.monitoredSessionID)
        XCTAssertEqual(harness.phases.last?.phase, .endpointReached)
        // Stopped: no further poll is scheduled.
        await harness.yieldRepeatedly()
        XCTAssertEqual(harness.clock.pendingSleepCount, 0)
    }

    func testPollsFollowTheRecordingAsItGrows() {
        let harness = MonitorHarness()
        defer { harness.tearDown() }
        let sessionID = UUID()
        harness.monitor.start(sessionID: sessionID, silenceDuration: 1)

        harness.recording.append(ScriptedAudio.speech(0.5))
        harness.monitor.poll(sessionID: sessionID)
        XCTAssertEqual(harness.monitor.phase, .listening)

        harness.recording.append(ScriptedAudio.silence(0.5))
        harness.monitor.poll(sessionID: sessionID)
        XCTAssertEqual(harness.monitor.phase, .stopping(remaining: 0.5))
        XCTAssertTrue(harness.endpoints.isEmpty)

        harness.recording.append(ScriptedAudio.silence(0.5))
        harness.monitor.poll(sessionID: sessionID)
        XCTAssertEqual(harness.endpoints, [sessionID])
        XCTAssertEqual(
            harness.phases.map(\.phase),
            [.listening, .stopping(remaining: 0.5), .endpointReached]
        )
    }

    func testTimerThatFiresAfterAManualStopDoesNothing() async throws {
        let harness = MonitorHarness()
        defer { harness.tearDown() }
        harness.monitor.start(sessionID: UUID(), silenceDuration: 1)
        harness.recording.append(ScriptedAudio.speech(0.5) + ScriptedAudio.silence(1))
        try await harness.waitForPendingSleep()

        // The user stops the recording while the next poll is already scheduled.
        harness.monitor.stop()
        harness.clock.fireNext()
        await harness.yieldRepeatedly()

        XCTAssertTrue(harness.endpoints.isEmpty)
        XCTAssertTrue(harness.phases.isEmpty)
        XCTAssertNil(harness.monitor.monitoredSessionID)
    }

    func testStalePollForAnEndedSessionDoesNotTouchTheNewSession() {
        let harness = MonitorHarness()
        defer { harness.tearDown() }
        let firstSessionID = UUID()
        harness.monitor.start(sessionID: firstSessionID, silenceDuration: 1)
        harness.recording.append(ScriptedAudio.speech(0.5) + ScriptedAudio.silence(1))

        let secondSessionID = UUID()
        harness.recording.reset()
        harness.monitor.start(sessionID: secondSessionID, silenceDuration: 1)
        harness.recording.append(ScriptedAudio.speech(0.5) + ScriptedAudio.silence(0.2))

        harness.monitor.poll(sessionID: firstSessionID)
        XCTAssertTrue(harness.endpoints.isEmpty)
        XCTAssertTrue(harness.phases.isEmpty)
        XCTAssertEqual(harness.monitor.phase, .waitingForSpeech)

        harness.monitor.poll(sessionID: secondSessionID)
        XCTAssertEqual(harness.monitor.phase, .listening)
        harness.recording.append(ScriptedAudio.silence(0.8))
        harness.monitor.poll(sessionID: secondSessionID)
        XCTAssertEqual(harness.endpoints, [secondSessionID])
        XCTAssertEqual(Set(harness.phases.map(\.sessionID)), [secondSessionID])
    }

    func testRestartingForANewSessionCancelsTheOldTimer() async throws {
        let harness = MonitorHarness()
        defer { harness.tearDown() }
        harness.monitor.start(sessionID: UUID(), silenceDuration: 1)
        try await harness.waitForPendingSleep()

        let secondSessionID = UUID()
        harness.recording.reset()
        harness.monitor.start(sessionID: secondSessionID, silenceDuration: 1)
        try await harness.waitForPendingSleep(count: 2)
        harness.recording.append(ScriptedAudio.speech(0.5) + ScriptedAudio.silence(1))

        // The first session's timer fires late; its task was cancelled and ends without a poll.
        harness.clock.fireNext()
        await harness.yieldRepeatedly()
        XCTAssertTrue(harness.endpoints.isEmpty)

        harness.clock.fireNext()
        try await harness.waitUntil { harness.endpoints.count == 1 }
        XCTAssertEqual(harness.endpoints, [secondSessionID])
    }
}
