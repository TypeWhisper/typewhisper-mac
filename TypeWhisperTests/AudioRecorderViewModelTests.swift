import AudioToolbox
import AVFoundation
import Combine
import XCTest
import os
import TypeWhisperPluginSDK
@testable import TypeWhisper

private actor RecorderStopFinalizationGate {
    private var continuation: CheckedContinuation<URL?, any Error>?
    private var started = false
    private var outputURL: URL?

    func wait(outputURL: URL) async throws -> URL? {
        started = true
        self.outputURL = outputURL
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func resume() {
        continuation?.resume(returning: outputURL)
        continuation = nil
    }
}

private actor RecorderStartGate {
    private var continuation: CheckedContinuation<URL, Never>?
    private var started = false
    private var outputURL: URL?

    func wait(outputURL: URL) async -> URL {
        started = true
        self.outputURL = outputURL
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool {
        started
    }

    func resume() {
        guard let continuation, let outputURL else { return }
        continuation.resume(returning: outputURL)
        self.continuation = nil
    }
}

private final class BlockingRecordingsLoader: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var _ranOnMainThread = false

    var ranOnMainThread: Bool {
        lock.withLock { _ranOnMainThread }
    }

    func load(
        directory: URL,
        transientFailures: [String: AudioRecorderViewModel.RecordingTranscriptionFailure]
    ) -> [AudioRecorderViewModel.RecordingItem] {
        lock.withLock {
            _ranOnMainThread = Thread.isMainThread
        }
        started.signal()
        release.wait()
        return []
    }
}

private final class OutOfOrderRecordingsLoader: @unchecked Sendable {
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var callCount = 0
    private let firstResult: [AudioRecorderViewModel.RecordingItem]
    private let secondResult: [AudioRecorderViewModel.RecordingItem]

    init(
        firstResult: [AudioRecorderViewModel.RecordingItem],
        secondResult: [AudioRecorderViewModel.RecordingItem]
    ) {
        self.firstResult = firstResult
        self.secondResult = secondResult
    }

    func load(
        directory: URL,
        transientFailures: [String: AudioRecorderViewModel.RecordingTranscriptionFailure]
    ) -> [AudioRecorderViewModel.RecordingItem] {
        let invocation = lock.withLock {
            callCount += 1
            return callCount
        }
        guard invocation == 1 else { return secondResult }

        firstStarted.signal()
        releaseFirst.wait()
        firstFinished.signal()
        return firstResult
    }
}

private final class BlockingRecorderCompletionsLoader: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var usedMainThread = false

    var callCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { usedMainThread } }

    func load(directory: URL, since: Date?) throws -> [RecorderTranscriptReadyPayload] {
        let invocation = lock.withLock {
            count += 1
            usedMainThread = usedMainThread || Thread.isMainThread
            return count
        }
        if invocation == 1 {
            release.wait()
            // Simulate a read of a sidecar while its deletion was in progress.
            throw CocoaError(.fileReadNoSuchFile)
        }
        return []
    }
}

@MainActor
final class AudioRecorderViewModelTests: XCTestCase {
    func testRecordingRequestSuppressesWhatsNewBeforeAsyncStartup() async throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: UserDefaultsKeys.setupWizardCompleted)
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        let previous = WhatsNewCoordinator.shared
        WhatsNewCoordinator.shared = coordinator
        defer { WhatsNewCoordinator.shared = previous }

        let viewModel = makeViewModel(defaults: defaults)
        // Reject before accessing hardware; the recording intent must still win.
        viewModel.micEnabled = false
        viewModel.systemAudioEnabled = false
        viewModel.startRecording()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(coordinator.isSuppressedForLaunch)
        XCTAssertTrue(coordinator.hasUnseenContent)
        await Task.yield()
    }

    /// A recording resets the error; the same error in a later recording is announced again.
    func testSameRecorderErrorAndWarningAreAnnouncedAgainAfterBeingCleared() throws {
        final class Announcements {
            var messages: [String] = []
            var now = ContinuousClock.now
        }
        let announcements = Announcements()
        let announcer = AccessibilityAnnouncementService()
        announcer.isVoiceOverEnabled = { true }
        // Far apart, so the service's one-second duplicate window never applies here.
        announcer.now = {
            announcements.now = announcements.now.advanced(by: .seconds(5))
            return announcements.now
        }
        announcer.post = { message, _ in announcements.messages.append(message) }
        let viewModel = makeViewModel(defaults: try makeDefaults(), accessibilityAnnouncementService: announcer)

        viewModel.errorMessage = "Microphone unavailable"
        viewModel.errorMessage = "Microphone unavailable"
        viewModel.errorMessage = nil
        viewModel.errorMessage = "Microphone unavailable"
        viewModel.systemAudioWarningMessage = "No system audio"
        viewModel.systemAudioWarningMessage = nil
        viewModel.systemAudioWarningMessage = "No system audio"

        let error = String(localized: "Error: \("Microphone unavailable")")
        XCTAssertEqual(announcements.messages, [error, error, "No system audio", "No system audio"])
    }

    private struct RestorableRecorderFixture {
        let viewModel: AudioRecorderViewModel
        let plugin: AudioRecorderRestorableTranscriptionPlugin
        let recording: AudioRecorderViewModel.RecordingItem
        let transcriptURL: URL
        let failureURL: URL
    }

    func testRecorderCompletionsReadOffMainThreadAndRetryConcurrentDeletion() async throws {
        let probe = BlockingRecorderCompletionsLoader()
        defer { probe.release.signal() }
        let directory = makeTemporaryDirectory()
        let viewModel = makeViewModel(defaults: try makeDefaults(), recorderCompletionsLoader: probe.load)
        let lookup = Task { try await viewModel.apiRecorderRecordings() }
        var started = false
        for _ in 0..<100 {
            if probe.callCount > 0 { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(started)
        let audioURL = directory.appendingPathComponent("Deleted.wav")
        try Data("audio".utf8).write(to: audioURL)
        viewModel.deleteRecording(AudioRecorderViewModel.RecordingItem(
            url: audioURL, date: Date(), duration: 1, fileSize: 5, transcript: nil, transcriptionFailure: nil
        ))
        probe.release.signal()
        let completions = try await lookup.value
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(probe.callCount, 2)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testRecorderReadyIsEmittedOnlyAfterDurableSaveWithoutLivePreview() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Meeting — Grüße 中文"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: try makeDefaults(), modelManager: modelManager)
        var events: [RecorderTranscriptReadyPayload] = []
        var dictationEvents = 0
        EventBus.shared.emissionObserverForTesting = { event in
            if case .transcriptionCompleted = event { dictationEvents += 1 }
            guard case .recorderTranscriptReady(let payload) = event else { return }
            events.append(payload)
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.audioFilePath))
            do {
                let savedText = try String(contentsOfFile: payload.transcriptFilePath, encoding: .utf8)
                let receipt = try JSONDecoder().decode(RecorderTranscriptReadyPayload.self, from:
                    Data(contentsOf: URL(fileURLWithPath: payload.audioFilePath + ".transcript-ready.json")))
                XCTAssertEqual(savedText, payload.text)
                XCTAssertEqual(receipt, payload, "Receipt must be readable before emission")
            } catch {
                XCTFail("Event preceded durable save: \(error)")
            }
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        _ = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.text, "Meeting — Grüße 中文")
        XCTAssertNil(events.first?.markdownFilePath)
        XCTAssertEqual(dictationEvents, 0, "Recorder must not invoke dictation subscribers such as Memory")
    }

    func testRecorderSpeakerRecordCarriesTheRecordingID() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Meeting notes"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: try makeDefaults(), modelManager: modelManager)
        viewModel.detectSpeakers = true
        var inputs: [SpeakerRecordingInput] = []
        viewModel.speakerRecordIntake = { input in
            inputs.append(input)
            return UUID()
        }
        var events: [RecorderTranscriptReadyPayload] = []
        EventBus.shared.emissionObserverForTesting = { event in
            guard case .recorderTranscriptReady(let payload) = event else { return }
            events.append(payload)
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        _ = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(inputs.first?.recorderRecordingID, events.first?.recordingID)
    }

    /// Issue #887: with speaker detection the completion waits for the speakers,
    /// so a receiver gets one delivery that tells who said what.
    func testRecorderCompletionWaitsForSpeakerDetection() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Ship it. Agreed."))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: try makeDefaults(), modelManager: modelManager)
        viewModel.detectSpeakers = true
        viewModel.speakerRecordIntake = { _ in UUID() }
        var detection: CheckedContinuation<Void, Never>?
        var waited: [Bool] = []
        viewModel.addingRecorderSpeakers = { payload, waits in
            waited.append(waits)
            await withCheckedContinuation { detection = $0 }
            var payload = payload
            payload.speakerState = "ready"
            payload.speakers = [RecorderSpeaker(id: "S1", name: "Me", isMe: true)]
            return payload
        }
        var events: [RecorderTranscriptReadyPayload] = []
        EventBus.shared.emissionObserverForTesting = { event in
            guard case .recorderTranscriptReady(let payload) = event else { return }
            events.append(payload)
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        _ = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        try await waitUntil("the completion waits for the speakers") { detection != nil }

        XCTAssertEqual(waited, [true])
        XCTAssertTrue(events.isEmpty, "The completion must not go out before speaker detection")
        detection?.resume()
        try await waitUntil("the completion is emitted") { events.count == 1 }
        XCTAssertEqual(events.first?.text, "Ship it. Agreed.")
        XCTAssertEqual(events.first?.speakerState, "ready")
        XCTAssertEqual(events.first?.speakers?.first?.isMe, true)
    }

    /// Issue #1558: a recording transcribed while Detect Speakers was off has a
    /// `.txt` but no speaker record; transcribing it again must add one.
    func testTranscribingAgainAddsTheSpeakerRecordARecordingDoesNotHaveYet() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Meeting notes"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let defaults = try makeDefaults()
        let first = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager, recordingsDirectory: directory)
        first.detectSpeakers = false
        var firstInputs: [SpeakerRecordingInput] = []
        first.speakerRecordIntake = { input in
            firstInputs.append(input)
            return UUID()
        }
        let sessionID = try await first.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try first.apiStopRecording()
        _ = try await waitForRecorderSession(first, id: sessionID, status: .completed)
        XCTAssertTrue(firstInputs.isEmpty)
        let completions = try await first.apiRecorderRecordings()
        let original = try XCTUnwrap(completions.first)

        let reloaded = makeViewModel(
            defaults: defaults, modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: directory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        reloaded.detectSpeakers = true
        var inputs: [SpeakerRecordingInput] = []
        reloaded.speakerRecordIntake = { input in
            inputs.append(input)
            return UUID()
        }
        try await waitForRecordingsToLoad(reloaded, count: 1)
        reloaded.transcribeRecording(try XCTUnwrap(reloaded.recordings.first))
        try await waitForRetranscriptionToFinish(reloaded)

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.recorderRecordingID, original.recordingID)
        XCTAssertEqual(inputs.first?.source, .recorder)
    }

    // Issue #1553: Whisper writes text for the quiet start of a call.
    func testRecorderSendsOnlySpeechToTheEngineAndKeepsRecordingTimes() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .timed(
            text: "Hello there. See you Thursday.",
            segments: [
                PluginTranscriptionSegment(text: "Hello there.", start: 1, end: 9),
                // Starts in the pause between the two parts.
                PluginTranscriptionSegment(text: "See you Thursday.", start: 10.2, end: 14),
            ],
            words: [PluginWordTiming(text: "Thursday.", start: 12, end: 14)]
        ))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let sampleRate = AudioRecorderService.transcriptionSampleRate
        let samples = Array(repeating: Float(0.25), count: Int(60 * sampleRate))
        let viewModel = makeFinalTranscriptionViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            samples: samples,
            speechRegionDetector: FixedSpeechRegionDetector(regions: [10...20, 40...45])
        )
        viewModel.detectSpeakers = true
        var inputs: [SpeakerRecordingInput] = []
        viewModel.speakerRecordIntake = { input in
            inputs.append(input)
            return UUID()
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)

        XCTAssertEqual(session.text, "Hello there. See you Thursday.")
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq") as? AudioRecorderMockTranscriptionPlugin
        )
        XCTAssertEqual(plugin.requests.count, 1)
        // 10 s and 5 s of speech with a half-second pause between them.
        XCTAssertEqual(plugin.requests.first?.audioSampleCount, Int(15.5 * sampleRate))

        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(input.samples.count, samples.count)
        XCTAssertEqual(input.result.duration, 60, accuracy: 0.001)
        XCTAssertEqual(input.result.segments.map(\.start), [11, 40])
        XCTAssertEqual(input.result.segments.map(\.end), [19, 43.5])
        XCTAssertEqual(input.result.words, [TranscriptionWord(text: "Thursday.", start: 41.5, end: 43.5)])
    }

    func testRecorderDoesNotTranscribeARecordingWithoutSpeech() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Продолжение следует..."))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            speechRegionDetector: FixedSpeechRegionDetector(regions: [])
        )

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        // A preview the engine wrote for the silence must not become the transcript.
        viewModel.partialText = "Thank you."
        _ = try viewModel.apiStopRecording()
        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)

        let noSpeech = String(localized: "recorder.noSpeechDetectedError")
        XCTAssertNil(session.text)
        XCTAssertTrue(session.error?.contains(noSpeech) == true)
        XCTAssertEqual(viewModel.partialText, "")
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq") as? AudioRecorderMockTranscriptionPlugin
        )
        XCTAssertTrue(plugin.requests.isEmpty)

        // An early library load can still show the recording without its failure.
        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.transcriptionFailure?.phase, .emptyResult)
        XCTAssertEqual(recording.transcriptionFailure?.providerError, noSpeech)
    }

    func testRecorderTranscribesTheWholeRecordingWhenSpeechDetectionFails() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("whole recording"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let samples = Array(repeating: Float(0.25), count: Int(3 * AudioRecorderService.transcriptionSampleRate))
        let viewModel = makeFinalTranscriptionViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            samples: samples,
            speechRegionDetector: FailingSpeechRegionDetector()
        )

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)

        XCTAssertEqual(session.text, "whole recording")
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq") as? AudioRecorderMockTranscriptionPlugin
        )
        XCTAssertEqual(plugin.requests.map(\.audioSampleCount), [samples.count])
    }

    func testRetranscribingARecordingWithoutSpeechKeepsTheTranscriptAndRecordsNoSpeech() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("Субтитры создавал DimaTorzok"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in Array(repeating: 0.25, count: 32_000) },
            speechRegionDetector: FixedSpeechRegionDetector(regions: [])
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: { $0.recordings.first?.transcriptionFailure != nil }
        )

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        let failure = try XCTUnwrap(viewModel.recordings.first?.transcriptionFailure)
        XCTAssertEqual(failure.phase, .emptyResult)
        XCTAssertEqual(failure.providerError, String(localized: "recorder.noSpeechDetectedError"))
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq") as? AudioRecorderMockTranscriptionPlugin
        )
        XCTAssertTrue(plugin.requests.isEmpty)
    }

    func testRecorderReadyCoversManualCalendarAndAPIRecordingsAfterReload() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("saved transcript"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let defaults = try makeDefaults()
        var emitted: [RecorderTranscriptReadyPayload] = []
        for source in ["manual", "calendar", "api"] {
            let recorderService = makeRecorderService(
                recordingsDirectory: directory, outputURL: directory.appendingPathComponent("\(source).wav")
            )
            let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
            viewModel.transcriptionEnabled = true
            viewModel.livePreviewEnabled = false
            EventBus.shared.emissionObserverForTesting = { event in
                if case .recorderTranscriptReady(let payload) = event { emitted.append(payload) }
            }
            switch source {
            case "manual":
                viewModel.startRecording()
                try await waitForRecorderState(viewModel, .recording)
                viewModel.stopRecording()
            case "calendar":
                let handle = try await viewModel.startCalendarMeetingRecording(
                    preferredBaseName: "Meeting", transcriptMetadata: makeCalendarMeetingTranscriptMetadata(title: "Meeting")
                )
                try viewModel.stopCalendarMeetingRecording(handle: handle)
            default:
                _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
                _ = try viewModel.apiStopRecording()
            }
            try await waitForRecorderState(viewModel, .idle)
        }
        XCTAssertEqual(emitted.count, 3)
        let calendar = try XCTUnwrap(emitted.first(where: { $0.audioFilePath.hasSuffix("calendar.wav") }))
        let markdownPath = try XCTUnwrap(calendar.markdownFilePath)
        XCTAssertTrue(try String(contentsOfFile: markdownPath, encoding: .utf8).contains("saved transcript"))

        let reloaded = makeViewModel(defaults: defaults, recorderService: makeRecorderService(recordingsDirectory: directory))
        let restored = try await reloaded.apiRecorderRecordings()
        XCTAssertEqual(restored, emitted)
        XCTAssertEqual(Set(emitted.map(\.recordingID)).count, 3)
        let last = try XCTUnwrap(emitted.last)
        let inclusive = try await reloaded.apiRecorderRecordings(since: last.completedAt)
        let future = try await reloaded.apiRecorderRecordings(since: last.completedAt.addingTimeInterval(1))
        XCTAssertEqual(inclusive, [last])
        XCTAssertTrue(future.isEmpty)

        try FileManager.default.removeItem(atPath: markdownPath)
        let withoutMarkdown = try await reloaded.apiRecorderRecordings()
        XCTAssertNil(withoutMarkdown.first(where: { $0.recordingID == calendar.recordingID })?.markdownFilePath)
        try FileManager.default.removeItem(atPath: last.transcriptFilePath)
        let withoutTranscript = try await reloaded.apiRecorderRecordings()
        XCTAssertFalse(withoutTranscript.contains(where: { $0.recordingID == last.recordingID }))
    }

    func testRecorderRetranscriptionKeepsIDAndDeletionRemovesReceipt() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("saved transcript"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let defaults = try makeDefaults()
        let firstModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager, recordingsDirectory: directory)
        let sessionID = try await firstModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try firstModel.apiStopRecording()
        _ = try await waitForRecorderSession(firstModel, id: sessionID, status: .completed)
        let initialCompletions = try await firstModel.apiRecorderRecordings()
        let original = try XCTUnwrap(initialCompletions.first)

        let reloaded = makeViewModel(
            defaults: defaults, modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: directory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        var events: [RecorderTranscriptReadyPayload] = []
        EventBus.shared.emissionObserverForTesting = { event in
            if case .recorderTranscriptReady(let payload) = event { events.append(payload) }
        }
        try await waitForRecordingsToLoad(reloaded, count: 1)
        reloaded.transcribeRecording(try XCTUnwrap(reloaded.recordings.first))
        try await waitForRetranscriptionToFinish(reloaded)
        let updatedCompletions = try await reloaded.apiRecorderRecordings()
        let updated = try XCTUnwrap(updatedCompletions.first)
        XCTAssertEqual(events, [updated])
        XCTAssertEqual(updated.recordingID, original.recordingID)
        XCTAssertNotEqual(updated.completionID, original.completionID)
        XCTAssertGreaterThanOrEqual(updated.completedAt, original.completedAt)
        XCTAssertEqual(updatedCompletions.count, 1)

        reloaded.deleteRecording(try XCTUnwrap(reloaded.recordings.first))
        let afterDeletion = try await reloaded.apiRecorderRecordings()
        XCTAssertTrue(afterDeletion.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.audioFilePath + ".transcript-ready.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.audioFilePath + ".recording-id.json"))
    }

    func testRecorderRetranscriptionRecoversIdentityWhenOneSidecarIsCorrupt() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("original transcript"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let defaults = try makeDefaults()
        let firstModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager, recordingsDirectory: directory)
        let sessionID = try await firstModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try firstModel.apiStopRecording()
        _ = try await waitForRecorderSession(firstModel, id: sessionID, status: .completed)
        let initialCompletions = try await firstModel.apiRecorderRecordings()
        let original = try XCTUnwrap(initialCompletions.first)
        var previousCompletionID = original.completionID
        setupPluginManager(groqBehavior: .success("repaired transcript"))

        for suffix in [".transcript-ready.json", ".recording-id.json"] {
            try Data("{truncated".utf8).write(to: URL(fileURLWithPath: original.audioFilePath + suffix))
            let reloaded = makeViewModel(
                defaults: defaults, modelManager: modelManager,
                recorderService: makeRecorderService(recordingsDirectory: directory),
                audioSamplesLoader: { _ in [0.25, -0.25] }
            )
            var events: [RecorderTranscriptReadyPayload] = []
            EventBus.shared.emissionObserverForTesting = { event in
                if case .recorderTranscriptReady(let payload) = event { events.append(payload) }
            }
            try await waitForRecordingsToLoad(reloaded, count: 1)
            reloaded.transcribeRecording(try XCTUnwrap(reloaded.recordings.first))
            try await waitForRetranscriptionToFinish(reloaded)

            XCTAssertEqual(events.count, 1, suffix)
            let repaired = try XCTUnwrap(events.first)
            XCTAssertEqual(repaired.recordingID, original.recordingID, "Recovery must preserve identity across restarts")
            XCTAssertNotEqual(repaired.completionID, previousCompletionID)
            XCTAssertEqual(repaired.text, "repaired transcript")
            XCTAssertEqual(try String(contentsOfFile: repaired.transcriptFilePath, encoding: .utf8), repaired.text)
            let persisted = try await reloaded.apiRecorderRecordings()
            XCTAssertEqual(persisted, [repaired])
            let identity = try JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: repaired.audioFilePath + ".recording-id.json"))) as? [String: String]
            XCTAssertEqual(identity?["recording_id"], original.recordingID.uuidString)
            previousCompletionID = repaired.completionID
        }

        for suffix in [".transcript-ready.json", ".recording-id.json"] {
            try Data("{truncated".utf8).write(to: URL(fileURLWithPath: original.audioFilePath + suffix))
        }
        let unrecoverable = makeViewModel(
            defaults: defaults, modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: directory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        var readyCount = 0
        EventBus.shared.emissionObserverForTesting = { event in
            if case .recorderTranscriptReady = event { readyCount += 1 }
        }
        try await waitForRecordingsToLoad(unrecoverable, count: 1)
        unrecoverable.transcribeRecording(try XCTUnwrap(unrecoverable.recordings.first))
        try await waitForRetranscriptionToFinish(unrecoverable, recordingsSatisfy: {
            $0.recordings.first?.transcriptionFailure?.phase == .savingTranscript
        })
        XCTAssertEqual(readyCount, 0, "Do not mint a different ID if both copies were lost")
        XCTAssertEqual(try String(contentsOfFile: original.transcriptFilePath, encoding: .utf8), "repaired transcript")
    }

    func testRecorderReadySkipsFailuresCancellationAndDisabledTranscription() async throws {
        try preserveStandardDefaults()
        let cases: [(AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior, Bool)] = [
            (.failure("provider failure"), true), (.empty, true), (.cancellation, true), (.success("unused"), false)
        ]
        for (behavior, transcriptionEnabled) in cases {
            setupPluginManager(groqBehavior: behavior)
            let modelManager = ModelManagerService()
            modelManager.selectProvider("groq")
            let viewModel = makeFinalTranscriptionViewModel(defaults: try makeDefaults(), modelManager: modelManager)
            viewModel.transcriptionEnabled = transcriptionEnabled
            var readyCount = 0
            EventBus.shared.emissionObserverForTesting = { event in
                if case .recorderTranscriptReady = event { readyCount += 1 }
            }
            _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
            _ = try viewModel.apiStopRecording()
            try await waitForRecorderState(viewModel, .idle)
            XCTAssertEqual(readyCount, 0)
            let completions = try await viewModel.apiRecorderRecordings()
            XCTAssertTrue(completions.isEmpty)
        }
    }

    func testRecorderReceiptFailureRestoresPreviousTranscriptWithoutEmitting() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("original transcript"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let viewModel = makeViewModel(
            defaults: try makeDefaults(), modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: directory),
            audioSamplesLoader: { _ in Array(repeating: 0.25, count: 16_000) }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false
        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        _ = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        let initialCompletions = try await viewModel.apiRecorderRecordings()
        let original = try XCTUnwrap(initialCompletions.first)
        let receiptURL = URL(fileURLWithPath: original.audioFilePath + ".transcript-ready.json")
        let receiptData = try Data(contentsOf: receiptURL)
        let identityURL = URL(fileURLWithPath: original.audioFilePath + ".recording-id.json")
        let identityData = try Data(contentsOf: identityURL)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: receiptURL.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: receiptURL.path) }
        setupPluginManager(groqBehavior: .success("replacement transcript"))
        var readyCount = 0
        EventBus.shared.emissionObserverForTesting = { event in
            if case .recorderTranscriptReady = event { readyCount += 1 }
        }
        try await waitForRecordingsToLoad(viewModel, count: 1)
        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel, recordingsSatisfy: {
            $0.recordings.first?.transcriptionFailure?.phase == .savingTranscript
        })
        XCTAssertEqual(readyCount, 0)
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptData)
        XCTAssertEqual(try Data(contentsOf: identityURL), identityData)
        XCTAssertEqual(try String(contentsOfFile: original.transcriptFilePath, encoding: .utf8), original.text)
        let afterFailure = try await viewModel.apiRecorderRecordings()
        XCTAssertEqual(afterFailure, [original])
    }

    func testRecorderRecordingsAPIValidatesSinceAndUsesExistingAuthorization() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let directory = makeTemporaryDirectory()
        let viewModel = makeFinalTranscriptionViewModel(defaults: try makeDefaults(), modelManager: modelManager, recordingsDirectory: directory)
        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        _ = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        let completions = try await viewModel.apiRecorderRecordings()
        let saved = try XCTUnwrap(completions.first)
        let router = APIRouter(authenticationProvider: { .required(token: "test-token") })
        router.register("GET", "/v1/recorder/recordings") { request in
            await APIHandlers.recorderRecordingsResponse(for: request, recorder: viewModel)
        }
        func request(since: String? = nil, authorized: Bool = true) -> HTTPRequest {
            HTTPRequest(method: "GET", path: "/v1/recorder/recordings",
                        queryParams: since.map { ["since": $0] } ?? [:],
                        headers: authorized ? ["authorization": "Bearer test-token"] : [:], body: Data())
        }
        let denied = await router.route(request(authorized: false))
        XCTAssertEqual(denied.status, 401)
        for invalid in ["", "garbage", "nan", "inf", "-1"] {
            let response = await router.route(request(since: invalid))
            XCTAssertEqual(response.status, 400, invalid)
        }
        struct Response: Decodable { let recordings: [RecorderTranscriptReadyPayload] }
        for since in [String(saved.completedAt.timeIntervalSince1970), "1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z"] {
            let response = await router.route(request(since: since))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try JSONDecoder().decode(Response.self, from: response.body).recordings, [saved])
        }
        let future = await router.route(request(since: String(saved.completedAt.timeIntervalSince1970 + 1)))
        XCTAssertTrue(try JSONDecoder().decode(Response.self, from: future.body).recordings.isEmpty)

        try Data("corrupt receipt".utf8).write(to: directory.appendingPathComponent("broken.wav.transcript-ready.json"))
        let failure = await router.route(request())
        XCTAssertEqual(failure.status, 500, "Never silently advance past an unreadable completion")
    }

    private func waitForRecorderState(_ viewModel: AudioRecorderViewModel, _ state: AudioRecorderViewModel.RecorderState) async throws {
        for _ in 0..<100 {
            if viewModel.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Recorder did not reach \(state)")
    }

    func testRecorderFilesAreLoadedOffMainThreadDuringInitialization() throws {
        let probe = BlockingRecordingsLoader()
        defer { probe.release.signal() }

        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            recordingsLoader: probe.load
        )

        XCTAssertEqual(probe.started.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(probe.ranOnMainThread)
        XCTAssertTrue(viewModel.recordings.isEmpty)
    }

    func testPrivacyQuietModeDefersInitialRecordingsLoadUntilRequested() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: UserDefaultsKeys.devPrivacyQuietMode)
        let probe = BlockingRecordingsLoader()
        defer { probe.release.signal() }

        let viewModel = makeViewModel(
            defaults: defaults,
            recordingsLoader: probe.load
        )

        XCTAssertEqual(probe.started.wait(timeout: .now() + 0.1), .timedOut)

        viewModel.loadRecordingsIfNeeded()

        XCTAssertEqual(probe.started.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testPrivacyQuietModeDefersDirectRecordingsRefreshUntilRequested() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: UserDefaultsKeys.devPrivacyQuietMode)
        let probe = BlockingRecordingsLoader()
        defer { probe.release.signal() }

        let viewModel = makeViewModel(
            defaults: defaults,
            recordingsLoader: probe.load
        )

        viewModel.loadRecordings()
        XCTAssertEqual(probe.started.wait(timeout: .now() + 0.1), .timedOut)

        viewModel.loadRecordingsIfNeeded()
        XCTAssertEqual(probe.started.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(probe.ranOnMainThread)
    }

    func testRecorderLoadIgnoresOlderResultThatFinishesLast() async throws {
        let directory = makeTemporaryDirectory()
        let olderURL = directory.appendingPathComponent("Older.wav")
        let newerURL = directory.appendingPathComponent("Newer.wav")
        let older = AudioRecorderViewModel.RecordingItem(
            url: olderURL,
            date: .distantPast,
            duration: 1,
            fileSize: 1,
            transcript: nil,
            transcriptionFailure: nil
        )
        let newer = AudioRecorderViewModel.RecordingItem(
            url: newerURL,
            date: .now,
            duration: 2,
            fileSize: 2,
            transcript: "new",
            transcriptionFailure: nil
        )
        let loader = OutOfOrderRecordingsLoader(firstResult: [older], secondResult: [newer])
        defer { loader.releaseFirst.signal() }
        let recorderService = makeRecorderService(recordingsDirectory: directory)
        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            recorderService: recorderService,
            recordingsLoader: loader.load
        )

        XCTAssertEqual(loader.firstStarted.wait(timeout: .now() + 1), .success)
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)
        XCTAssertEqual(viewModel.recordings.first?.url, newerURL)

        loader.releaseFirst.signal()
        XCTAssertEqual(loader.firstFinished.wait(timeout: .now() + 1), .success)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.recordings.first?.url, newerURL)
    }

    func testRecorderSelectionPersistsSeparatelyFromGlobalDefault() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-5-pro"

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), "assemblyai")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "universal-3-5-pro")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-3-5-pro")
    }

    func testRecorderSelectionFallsBackToGlobalDefaultWhenUnset() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-large-v3")
        XCTAssertEqual(viewModel.resolvedEngine?.providerId, "groq")
    }

    func testRecorderSelectionUsesModelOverrideWithDefaultEngine() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.selectedModel = "whisper-small"

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "whisper-small")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
    }

    func testDefaultEngineModelOverrideClearsWhenGlobalProviderChanges() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")

        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager)
        viewModel.selectedModel = "whisper-small"
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")

        modelManager.selectProvider("assemblyai")
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel))
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-2")
    }

    func testRecorderLanguagesFollowPerFlowDeepgramModel() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let deepgram = setupDeepgramPluginManager(globalModel: "nova-2")
        UserDefaults.standard.set("deepgram", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertFalse(viewModel.selectedEngineSupportedLanguages.contains("ar"))

        viewModel.selectedModel = "nova-3"
        viewModel.languageSelection = .exact("ar")
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertTrue(viewModel.selectedEngineSupportedLanguages.contains("ar"))
        XCTAssertEqual(viewModel.languageSelection, .exact("ar"))
        XCTAssertEqual(deepgram.selectedModelId, "nova-2")

        viewModel.selectedModel = "nova-2"
        XCTAssertEqual(viewModel.languageSelection, .auto)
    }

    func testRecorderKeepsMissingSavedEngineAndUsesDefaultEngine() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        defaults.set("missing-engine", forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        defaults.set("old-model", forKey: UserDefaultsKeys.recorderTranscriptionModel)
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertEqual(viewModel.selectedEngine, "missing-engine")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), "missing-engine")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "old-model")
        XCTAssertNil(viewModel.engineChoice)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-large-v3")
        XCTAssertEqual(viewModel.resolvedEngine?.providerId, "groq")
    }

    func testRecorderKeepsItsEngineWhilePluginIsUpdated() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)
        let viewModel = makeViewModel(defaults: defaults)
        viewModel.observePluginManager()
        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-5-pro"
        let pluginManager = try XCTUnwrap(PluginManager.shared)
        let assemblyAI = try XCTUnwrap(pluginManager.loadedPlugins.first { $0.manifest.id == "com.typewhisper.mock.assemblyai" })

        // An update unloads the plugin and loads the new version.
        pluginManager.unloadPlugin("com.typewhisper.mock.assemblyai", keepsSavedEngine: true)
        await drainMainQueue()

        XCTAssertEqual(viewModel.selectedEngine, "assemblyai")
        XCTAssertEqual(viewModel.selectedModel, "universal-3-5-pro")
        XCTAssertNil(viewModel.engineChoice)
        XCTAssertNil(viewModel.modelChoice)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-large-v3")

        pluginManager.loadedPlugins.append(assemblyAI)
        await drainMainQueue()

        XCTAssertEqual(viewModel.engineChoice, "assemblyai")
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-3-5-pro")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), "assemblyai")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "universal-3-5-pro")
    }

    func testModelChosenForTheDefaultEngineInPlaceOfAMissingOneSwitchesToIt() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        defaults.set("missing-engine", forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        defaults.set("old-model", forKey: UserDefaultsKeys.recorderTranscriptionModel)
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)
        let viewModel = makeViewModel(defaults: defaults)

        viewModel.modelChoice = "whisper-small"

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertEqual(viewModel.selectedModel, "whisper-small")
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")
    }

    func testRecordingStartedOnTheDefaultEngineFinishesOnIt() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager(groqBehavior: .success("default engine"), assemblyAIBehavior: .success("own engine"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)
        viewModel.selectedEngine = "assemblyai"
        let pluginManager = try XCTUnwrap(PluginManager.shared)
        let assemblyAI = try XCTUnwrap(pluginManager.loadedPlugins.first { $0.manifest.id == "com.typewhisper.mock.assemblyai" })
        pluginManager.unloadPlugin("com.typewhisper.mock.assemblyai", keepsSavedEngine: true)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        // The plugin comes back during the recording.
        pluginManager.loadedPlugins.append(assemblyAI)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "default engine")
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
    }

    func testRecorderForgetsAnUninstalledEngine() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)
        let viewModel = makeViewModel(defaults: defaults)
        viewModel.observePluginManager()
        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-5-pro"

        try XCTUnwrap(PluginManager.shared).unloadPlugin("com.typewhisper.mock.assemblyai")
        await drainMainQueue()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine))
    }

    func testRecorderForgetsAnEngineUninstalledWhileDisabled() async throws {
        let pluginId = "com.typewhisper.mock.assemblyai"
        try preserveStandardDefaults(additionalKeys: [
            "plugin.\(pluginId).enabled",
            PluginManager.disabledEngineIdsKey(pluginId)
        ])
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)
        let viewModel = makeViewModel(defaults: defaults)
        viewModel.observePluginManager()
        viewModel.selectedEngine = "assemblyai"
        let pluginManager = try XCTUnwrap(PluginManager.shared)

        pluginManager.setPluginEnabled(pluginId, enabled: false)
        await drainMainQueue()
        XCTAssertEqual(viewModel.selectedEngine, "assemblyai")

        pluginManager.unloadPlugin(pluginId)
        await drainMainQueue()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(UserDefaults.standard.object(forKey: PluginManager.disabledEngineIdsKey(pluginId)))
    }

    func testRecorderLivePreviewDefaultsOffAndPersistsSeparately() throws {
        let defaults = try makeDefaults()

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertFalse(viewModel.livePreviewEnabled)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.recorderLivePreviewEnabled))

        viewModel.livePreviewEnabled = true

        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.recorderLivePreviewEnabled))
    }

    func testRecorderLanguageSelectionPersistsSeparatelyFromFileTranscription() throws {
        let defaults = try makeDefaults()
        defaults.set("fr", forKey: UserDefaultsKeys.fileTranscriptionLanguage)

        let viewModel = makeViewModel(defaults: defaults)
        XCTAssertEqual(viewModel.languageSelection, .auto)

        viewModel.languageSelection = .hints(["nl", "en"])

        XCTAssertEqual(
            defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionLanguage),
            "[\"nl\",\"en\"]"
        )
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.fileTranscriptionLanguage), "fr")

        let restoredViewModel = makeViewModel(defaults: defaults)
        XCTAssertEqual(restoredViewModel.languageSelection, .hints(["nl", "en"]))
    }

    func testLivePreviewStartsOnlyWhenTranscriptAndPreviewAreEnabled() async throws {
        try preserveStandardDefaults()
        setupPluginManager()

        let disabledCount = try await livePreviewStartCount(
            transcriptionEnabled: false,
            livePreviewEnabled: true
        )
        let transcriptOnlyCount = try await livePreviewStartCount(
            transcriptionEnabled: true,
            livePreviewEnabled: false
        )
        let splitEnabledCount = try await livePreviewStartCount(
            transcriptionEnabled: true,
            livePreviewEnabled: true
        )

        XCTAssertEqual(disabledCount, 0)
        XCTAssertEqual(transcriptOnlyCount, 0)
        XCTAssertEqual(splitEnabledCount, 1)
    }

    func testRecorderStartPassesResolvedMicrophonePrioritySelection() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let usbDeviceID = AudioDeviceID(620)
        let usbDevice = AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        let audioDeviceService = AudioDeviceService(
            initialInputDevices: [usbDevice],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        audioDeviceService.addInputDeviceToPriorityList(usbDevice)

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: recorderService,
            audioDeviceService: audioDeviceService
        )

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        XCTAssertEqual(capturedSelection?.deviceUID, "usb-input")
        XCTAssertEqual(capturedSelection?.deviceID, usbDeviceID)
        XCTAssertTrue(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testRecorderStartIgnoresMicrophonePriorityWhenMicDisabled() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let usbDeviceID = AudioDeviceID(621)
        let usbDevice = AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        let audioDeviceService = AudioDeviceService(
            initialInputDevices: [usbDevice],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        audioDeviceService.addInputDeviceToPriorityList(usbDevice)

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        var capturedSelection: ResolvedRecordingInputSelection?
        recorderService.startRecordingOverride = { _, _, _, outputURL, microphoneSelection in
            capturedSelection = microphoneSelection
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }

        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: recorderService,
            audioDeviceService: audioDeviceService
        )

        _ = try await viewModel.apiStartRecording(micEnabled: false, systemAudioEnabled: true)

        XCTAssertNil(capturedSelection?.deviceUID)
        XCTAssertNil(capturedSelection?.deviceID)
        XCTAssertFalse(capturedSelection?.hasExplicitDeviceSelection == true)
    }

    func testFinalTranscriptionFailurePersistsRecorderFailureAndFailsAPISession() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("HTTP 413: payload too large"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(try viewModel.apiStopRecording(), sessionID)

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        let outputFile = try XCTUnwrap(session.outputFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile))
        XCTAssertNil(session.text)
        XCTAssertTrue(session.error?.contains("HTTP 413") == true)

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(
            recording.url.resolvingSymlinksInPath().path,
            URL(fileURLWithPath: outputFile).resolvingSymlinksInPath().path
        )
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .finalTranscription)
        XCTAssertEqual(failure.engineName, "Groq")
        XCTAssertEqual(failure.modelName, "Whisper Large V3")
        XCTAssertTrue(failure.providerError.contains("HTTP 413"))
        XCTAssertTrue(session.error?.contains(failure.phase.displayName) == true)

        let summary = try XCTUnwrap(viewModel.transcriptionFailureSummary(for: recording))
        XCTAssertTrue(summary.contains(viewModel.formattedDuration(recording.duration)))
        XCTAssertTrue(summary.contains(viewModel.formattedFileSize(recording.fileSize)))
        XCTAssertTrue(summary.contains(failure.phase.displayName))
        XCTAssertTrue(summary.contains("HTTP 413"))
    }

    func testCancelledFinalTranscriptionDoesNotPersistRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .cancellation)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        let outputFile = try XCTUnwrap(session.outputFile)
        XCTAssertNil(session.text)
        XCTAssertNil(session.error)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: failureSidecarURL(for: URL(fileURLWithPath: outputFile)).path
            )
        )

        try await waitForRecordingsToLoad(viewModel, count: 1)
        XCTAssertNil(viewModel.recordings.first?.transcriptionFailure)
    }

    func testEmptyFinalTranscriptionPersistsRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .empty)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNotNil(session.outputFile)
        XCTAssertNil(session.text)

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .emptyResult)
        XCTAssertFalse(failure.providerError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(session.error?.contains(failure.phase.displayName) == true)
        XCTAssertTrue(session.error?.contains(failure.providerError) == true)
    }

    func testDroppedLiveSessionRecordsFailureInsteadOfSavingPreview() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let livePlugin = AudioRecorderDroppingLivePlugin()
        PluginManager.shared.loadedPlugins.append(LoadedPlugin(
            manifest: PluginManifest(
                id: "com.typewhisper.mock.dropping-live",
                name: "Dropping Live",
                version: "1.0.0",
                principalClass: "AudioRecorderDroppingLivePlugin"
            ),
            instance: livePlugin,
            bundle: Bundle.main,
            sourceURL: makeTemporaryDirectory(),
            isEnabled: true
        ))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider(livePlugin.providerId)
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)
        viewModel.livePreviewEnabled = true
        var finalPartialTexts: [String] = []
        EventBus.shared.emissionObserverForTesting = { event in
            if case .partialTranscriptionUpdate(let payload) = event, payload.isFinal {
                finalPartialTexts.append(payload.text)
            }
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        for _ in 0..<50 where livePlugin.liveSessionCreateCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(livePlugin.liveSessionCreateCount, 1)
        // The preview froze at the words recognized before the connection dropped.
        viewModel.partialText = "words before the drop"
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNil(session.text)
        XCTAssertEqual(livePlugin.batchTranscriptionCount, 1)

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.transcriptionFailure?.phase, .finalTranscription)
        XCTAssertEqual(finalPartialTexts, [])
    }

    func testLiveSessionThatStopsReturningTextTranscribesFinalizedRecording() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let livePlugin = AudioRecorderStallingLivePlugin()
        PluginManager.shared.loadedPlugins.append(LoadedPlugin(
            manifest: PluginManifest(
                id: "com.typewhisper.mock.stalling-live",
                name: "Stalling Live",
                version: "1.0.0",
                principalClass: "AudioRecorderStallingLivePlugin"
            ),
            instance: livePlugin,
            bundle: Bundle.main,
            sourceURL: makeTemporaryDirectory(),
            isEnabled: true
        ))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider(livePlugin.providerId)
        // Six seconds of speech reach the live session, which never transcribes them.
        let captureSamples = Array(
            repeating: Float(0.25),
            count: Int(AudioRecorderService.transcriptionSampleRate * 6)
        )
        let finalizedFileSamples = Array(
            repeating: Float(0.3),
            count: Int(AudioRecorderService.transcriptionSampleRate * 6)
        )
        let recorderService = makeRecorderService(
            recordingsDirectory: makeTemporaryDirectory(),
            samples: captureSamples
        )
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            audioSamplesLoader: { _ in finalizedFileSamples }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = true

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        for _ in 0..<50 where livePlugin.liveSessionCreateCount == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(livePlugin.liveSessionCreateCount, 1)
        viewModel.partialText = "words before the stall"
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "complete transcript")
        XCTAssertEqual(livePlugin.batchTranscriptionSamples, finalizedFileSamples)

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcript != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(recording.transcript, "complete transcript")
        XCTAssertNil(recording.transcriptionFailure)
    }

    func testSuccessfulTranscriptSaveClearsPriorRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("fresh transcript"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let outputURL = recordingsDirectory.appendingPathComponent("Recording success.wav")
        let failureURL = failureSidecarURL(for: outputURL)
        let oldFailure = AudioRecorderViewModel.RecordingTranscriptionFailure(
            phase: .finalTranscription,
            providerError: "old error",
            engineName: "Groq",
            modelName: "Whisper Large V3",
            failedAt: Date.distantPast
        )
        try JSONEncoder().encode(oldFailure).write(to: failureURL, options: .atomic)

        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory,
            outputURL: outputURL
        )
        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "fresh transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureURL.path))

        // The library reloads in the background after the session completes, and an
        // early load can still show the recording without its transcript.
        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcript != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(recording.transcript, "fresh transcript")
        XCTAssertNil(recording.transcriptionFailure)
    }

    func testCalendarMeetingFinalTranscriptionUsesFinalizedRecordingSamples() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("complete meeting transcript"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let captureSamples = Array(
            repeating: Float(0.1),
            count: Int(AudioRecorderService.transcriptionSampleRate)
        )
        let finalizedFileSamples = Array(
            repeating: Float(0.6),
            count: Int(AudioRecorderService.transcriptionSampleRate * 2)
        )
        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory,
            samples: captureSamples
        )
        var loadedURL: URL?
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            audioSamplesLoader: { url in
                loadedURL = url
                return finalizedFileSamples
            }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let metadata = makeCalendarMeetingTranscriptMetadata(title: "RC2 Meeting")
        let handle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "RC2 Meeting",
            transcriptMetadata: metadata
        )
        try viewModel.stopCalendarMeetingRecording(handle: handle)

        // A load that runs while the transcript files are installed can see the
        // .txt before the calendar transcript document.
        try await waitForRecordingsToLoad(viewModel, count: 1) {
            $0.transcript != nil && $0.calendarEvent != nil
        }

        XCTAssertEqual(loadedURL?.standardizedFileURL, handle.outputURL.standardizedFileURL)
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq")
                as? AudioRecorderMockTranscriptionPlugin
        )
        let request = try XCTUnwrap(plugin.lastRequest)
        XCTAssertEqual(request.audioSampleCount, finalizedFileSamples.count)
        XCTAssertEqual(request.firstAudioSample, finalizedFileSamples.first)
        XCTAssertNotEqual(request.audioSampleCount, captureSamples.count)
        XCTAssertTrue(request.usedFileTranscriptionPipeline)
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(recording.transcript, "complete meeting transcript")
        XCTAssertEqual(recording.calendarEvent, metadata)

        let documentURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            RecordingTranscriptDocument.self,
            from: Data(contentsOf: documentURL)
        )
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.text, "complete meeting transcript")
        XCTAssertEqual(document.calendarEvent, metadata)

        let markdownURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        XCTAssertTrue(markdown.contains("title: \"RC2 Meeting\""))
        XCTAssertTrue(markdown.contains("# RC2 Meeting\n\ncomplete meeting transcript"))
    }

    func testCalendarMetadataPersistsWhenFinalTranscriptionFails() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("provider unavailable"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let viewModel = makeFinalTranscriptionViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recordingsDirectory: recordingsDirectory
        )
        let metadata = makeCalendarMeetingTranscriptMetadata(title: "Failed meeting")

        let handle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "Failed meeting",
            transcriptMetadata: metadata
        )
        try viewModel.stopCalendarMeetingRecording(handle: handle)
        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }

        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.calendarEvent, metadata)
        XCTAssertEqual(recording.transcriptionFailure?.phase, .finalTranscription)

        let documentURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.json")
        let markdownURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.md")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            RecordingTranscriptDocument.self,
            from: Data(contentsOf: documentURL)
        )
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNil(document.text)
        XCTAssertEqual(document.calendarEvent, metadata)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("title: \"Failed meeting\""))
        XCTAssertTrue(markdown.hasSuffix("# Failed meeting\n"))
    }

    func testManualStopDuringCalendarStartupPersistsMetadata() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        let startGate = RecorderStartGate()
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("starting".utf8).write(to: outputURL)
            return await startGate.wait(outputURL: outputURL)
        }
        recorderService.stopRecordingOverride = { outputURL in
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }
        let viewModel = makeViewModel(defaults: defaults, recorderService: recorderService)
        viewModel.transcriptionEnabled = false
        viewModel.livePreviewEnabled = false
        let metadata = makeCalendarMeetingTranscriptMetadata(title: "Startup race")

        let startTask = Task {
            try await viewModel.startCalendarMeetingRecording(
                preferredBaseName: "Startup race",
                transcriptMetadata: metadata
            )
        }
        for _ in 0..<100 where !(await startGate.hasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let startupDidSuspend = await startGate.hasStarted()
        XCTAssertTrue(startupDidSuspend)
        XCTAssertEqual(viewModel.state, .recording)

        viewModel.stopRecording()
        await startGate.resume()
        do {
            _ = try await startTask.value
            XCTFail("Expected startup to observe the manual stop")
        } catch let error as AudioRecorderViewModel.RecorderAPIError {
            guard case .notRecording = error else {
                return XCTFail("Expected notRecording, got \(error)")
            }
        }

        try await waitForRecordingsToLoad(viewModel, count: 1)
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(recording.calendarEvent, metadata)
        XCTAssertNil(recording.transcript)
    }

    func testCalendarMetadataPersistsWithoutTranscriptionAndIsDeletedWithRecording() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory)
        )
        viewModel.transcriptionEnabled = false
        viewModel.livePreviewEnabled = false

        let metadata = makeCalendarMeetingTranscriptMetadata(title: "Planning")
        let handle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "Planning",
            transcriptMetadata: metadata
        )
        try viewModel.stopCalendarMeetingRecording(handle: handle)

        try await waitForRecordingsToLoad(viewModel, count: 1)
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.calendarEvent, metadata)

        let documentURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.json")
        let markdownURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.md")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            RecordingTranscriptDocument.self,
            from: Data(contentsOf: documentURL)
        )
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertNil(document.text)
        XCTAssertEqual(document.calendarEvent, metadata)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("title: \"Planning\""))
        XCTAssertTrue(markdown.hasSuffix("# Planning\n"))

        viewModel.deleteRecording(recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
    }

    func testDeleteRecordingMovesAudioAndTranscriptToTheTrash() async throws {
        try preserveStandardDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let trash = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Interview.wav")
        let transcriptURL = recordingsDirectory.appendingPathComponent("Interview.txt")
        try Data("audio".utf8).write(to: audioURL)
        try Data("transcript".utf8).write(to: transcriptURL)
        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            trash: trash
        )
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.deleteRecording(try XCTUnwrap(viewModel.recordings.first))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
        let trashedContents = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(trashedContents), ["audio", "transcript"])
    }

    func testDeleteRecordingRetainsAudioWhenCalendarMetadataCannotBeDeleted() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let viewModel = makeViewModel(
            defaults: defaults,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory)
        )
        viewModel.transcriptionEnabled = false
        viewModel.livePreviewEnabled = false

        let handle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "Protected metadata",
            transcriptMetadata: makeCalendarMeetingTranscriptMetadata(title: "Protected metadata")
        )
        try viewModel.stopCalendarMeetingRecording(handle: handle)
        try await waitForRecordingsToLoad(viewModel, count: 1)

        let recording = try XCTUnwrap(viewModel.recordings.first)
        let documentURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.json")
        let markdownURL = handle.outputURL
            .deletingPathExtension()
            .appendingPathExtension("transcript.md")
        let markdownBeforeDeletion = try Data(contentsOf: markdownURL)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: documentURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: documentURL.path
            )
        }

        viewModel.deleteRecording(recording)

        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: documentURL.path))
        XCTAssertEqual(try Data(contentsOf: markdownURL), markdownBeforeDeletion)
        XCTAssertEqual(viewModel.recordings.map(\.id), [recording.id])
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testFinalTranscriptionDoesNotForceGlobalDefaultModelAsRecorderOverride() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let appSupportDirectory = makeTemporaryDirectory()
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let plugin = RecorderOverrideMarkerTranscriptionPlugin()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: RecorderOverrideMarkerTranscriptionPlugin.pluginId,
                    name: RecorderOverrideMarkerTranscriptionPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "RecorderOverrideMarkerTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)
        let viewModel = makeFinalTranscriptionViewModel(defaults: defaults, modelManager: modelManager)

        XCTAssertNil(viewModel.selectedModel)

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "unforced whisper-large-v3")
        XCTAssertEqual(plugin.selectedModelOverrides, [])
    }

    func testWhisperKitChunkFailureIsNotHiddenByLivePreview() async throws {
        try preserveStandardDefaults()
        _ = setupWhisperPluginManager(behavior: .failure("WhisperKit could not transcribe audio segment 2 of 3"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let directory = makeTemporaryDirectory()
        let viewModel = makeFinalTranscriptionViewModel(
            defaults: try makeDefaults(), modelManager: modelManager, recordingsDirectory: directory
        )
        viewModel.livePreviewEnabled = true
        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        viewModel.partialText = "only the live preview"
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNil(session.text)
        XCTAssertTrue(session.error?.contains("segment 2 of 3") == true)
        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNotNil(recording.transcriptionFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.deletingPathExtension().appendingPathExtension("txt").path))
    }

    func testWhisperKitFailedDictionaryRetryDoesNotSaveTruncatedInitialResult() async throws {
        try preserveStandardDefaults()
        let plugin = setupWhisperPluginManager(behavior: .conditionedShortFallbackFailure)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let directory = makeTemporaryDirectory()
        let samples = Array(repeating: Float(0.1), count: 90 * Int(AudioRecorderService.transcriptionSampleRate))
        let dictionary = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionary.addEntry(type: .term, original: "TypeWhisper")
        let viewModel = makeViewModel(
            defaults: try makeDefaults(), modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: directory, samples: samples),
            dictionaryService: dictionary, audioSamplesLoader: { _ in samples }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false
        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNil(session.text)
        XCTAssertEqual(plugin.requests.count, 2)
        XCTAssertTrue(session.error?.contains("segment 2 of 3") == true)
        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        XCTAssertNotNil(viewModel.recordings.first?.transcriptionFailure)
    }

    func testWhisperKitFinalTranscriptionRetriesWithLivePreviewEnabledForAudibleTail() async throws {
        try preserveStandardDefaults()
        let plugin = setupWhisperPluginManager(
            behavior: .conditionedShortFallbackComplete(
                shortText: "short conditioned transcript",
                completeText: "complete unconditioned transcript"
            )
        )
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let recordingsDirectory = makeTemporaryDirectory()
        let samples = Array(
            repeating: Float(0.1),
            count: Int(AudioRecorderService.transcriptionSampleRate * 90)
        )
        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        var livePreviewStartCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(
                recordingsDirectory: recordingsDirectory,
                samples: samples
            ),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { _ in samples },
            livePreviewStartObserver: { livePreviewStartCount += 1 }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = true

        let sessionID = try await viewModel.apiStartRecording(
            micEnabled: true,
            systemAudioEnabled: false
        )
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "complete unconditioned transcript")
        XCTAssertEqual(livePreviewStartCount, 1)
        XCTAssertEqual(plugin.requests.count, 2)
        XCTAssertTrue(plugin.requests[0].prompt?.contains("TypeWhisper") == true)
        XCTAssertNil(plugin.requests[1].prompt)
    }

    func testWhisperKitFinalTranscriptionKeepsConditionedResultWhenRemainingTailIsSilent() async throws {
        try preserveStandardDefaults()
        let plugin = setupWhisperPluginManager(
            behavior: .conditionedShortFallbackComplete(
                shortText: "complete speech before silence",
                completeText: "unexpected retry"
            )
        )
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let recordingsDirectory = makeTemporaryDirectory()
        let sampleRate = Int(AudioRecorderService.transcriptionSampleRate)
        let samples = Array(repeating: Float(0.1), count: sampleRate * 18)
            + Array(repeating: Float.zero, count: sampleRate * 72)
        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(
                recordingsDirectory: recordingsDirectory,
                samples: samples
            ),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { _ in samples }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(
            micEnabled: true,
            systemAudioEnabled: false
        )
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "complete speech before silence")
        XCTAssertEqual(plugin.requests.count, 1)
        XCTAssertTrue(plugin.requests[0].prompt?.contains("TypeWhisper") == true)
    }

    func testWhisperKitEmptyFinalTranscriptionDoesNotRetrySilentAudio() async throws {
        try preserveStandardDefaults()
        let plugin = setupWhisperPluginManager(behavior: .empty)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let recordingsDirectory = makeTemporaryDirectory()
        let samples = Array(
            repeating: Float.zero,
            count: Int(AudioRecorderService.transcriptionSampleRate * 90)
        )
        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(
                recordingsDirectory: recordingsDirectory,
                samples: samples
            ),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { _ in samples }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(
            micEnabled: true,
            systemAudioEnabled: false
        )
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertNil(session.text)
        XCTAssertEqual(plugin.requests.count, 1)
        XCTAssertTrue(plugin.requests[0].prompt?.contains("TypeWhisper") == true)
    }

    func testWhisperKitEmptyFinalTranscriptionRetriesForAudibleRecordingStart() async throws {
        try preserveStandardDefaults()
        let plugin = setupWhisperPluginManager(
            behavior: .conditionedShortFallbackComplete(
                shortText: "",
                completeText: "recovered transcript"
            )
        )
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("whisper")
        let recordingsDirectory = makeTemporaryDirectory()
        let sampleRate = Int(AudioRecorderService.transcriptionSampleRate)
        let samples = Array(repeating: Float(0.1), count: sampleRate)
            + Array(repeating: Float.zero, count: sampleRate * 89)
        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(
                recordingsDirectory: recordingsDirectory,
                samples: samples
            ),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { _ in samples }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(
            micEnabled: true,
            systemAudioEnabled: false
        )
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "recovered transcript")
        XCTAssertEqual(plugin.requests.count, 2)
        XCTAssertTrue(plugin.requests[0].prompt?.contains("TypeWhisper") == true)
        XCTAssertNil(plugin.requests[1].prompt)
    }

    func testFailureSidecarWriteErrorStillShowsRecorderFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("HTTP 500: provider unavailable"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let outputURL = recordingsDirectory.appendingPathComponent("Recording write-error.wav")
        let failureURL = failureSidecarURL(for: outputURL)
        try FileManager.default.createDirectory(at: failureURL, withIntermediateDirectories: true)

        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory,
            outputURL: outputURL
        )
        let viewModel = makeViewModel(defaults: defaults, modelManager: modelManager, recorderService: recorderService)
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertTrue(session.error?.contains("HTTP 500") == true)

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        let failure = try XCTUnwrap(recording.transcriptionFailure)
        XCTAssertEqual(failure.phase, .finalTranscription)
        XCTAssertTrue(failure.providerError.contains("HTTP 500"))
        XCTAssertGreaterThan(failure.providerError.count, "API error: HTTP 500: provider unavailable".count)
        let sidecarValues = try failureURL.resourceValues(forKeys: [.isDirectoryKey])
        XCTAssertEqual(sidecarValues.isDirectory, true)
    }

    func testRetranscriptionUsesRecorderOverridesAndReplacesTranscriptAfterSuccess() async throws {
        try preserveStandardDefaults()
        setupPluginManager(
            groqBehavior: .success("wrong engine"),
            assemblyAIBehavior: .success("fresh retranscription")
        )
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.m4a")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let failureURL = failureSidecarURL(for: audioURL)
        let documentURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
        let metadata = makeCalendarMeetingTranscriptMetadata(title: "Meeting")
        try Data("audio".utf8).write(to: audioURL)
        try "old transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RecordingTranscriptDocument(
            text: "old transcript",
            calendarEvent: metadata
        )).write(to: documentURL, options: .atomic)
        let oldFailure = AudioRecorderViewModel.RecordingTranscriptionFailure(
            phase: .finalTranscription,
            providerError: "old failure",
            engineName: "Groq",
            modelName: "Whisper Large V3",
            failedAt: .distantPast
        )
        try JSONEncoder().encode(oldFailure).write(to: failureURL, options: .atomic)

        let dictionaryService = DictionaryService(appSupportDirectory: makeTemporaryDirectory())
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        var loadedURL: URL?
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            dictionaryService: dictionaryService,
            audioSamplesLoader: { url in
                loadedURL = url
                return [0.25, -0.25]
            }
        )
        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-5-pro"
        viewModel.languageSelection = .exact("de")
        viewModel.selectedTask = .translate
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        let recording = try XCTUnwrap(viewModel.recordings.first)
        viewModel.transcribeRecording(recording)
        XCTAssertFalse(viewModel.canToggleRecording)
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcript == "fresh retranscription"
                    && $0.recordings.first?.transcriptionFailure == nil
            }
        )

        XCTAssertEqual(loadedURL?.standardizedFileURL, audioURL.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "fresh retranscription")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureURL.path))
        XCTAssertEqual(viewModel.recordings.first?.transcript, "fresh retranscription")
        XCTAssertNil(viewModel.recordings.first?.transcriptionFailure)
        XCTAssertEqual(viewModel.recordings.first?.calendarEvent, metadata)
        XCTAssertTrue(viewModel.canToggleRecording)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            RecordingTranscriptDocument.self,
            from: Data(contentsOf: documentURL)
        )
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.text, "fresh retranscription")
        XCTAssertEqual(document.calendarEvent, metadata)
        let markdownURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.md")
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Meeting\n\nfresh retranscription"))

        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "assemblyai") as? AudioRecorderMockTranscriptionPlugin
        )
        let request = try XCTUnwrap(plugin.lastRequest)
        XCTAssertEqual(request.language, "de")
        XCTAssertTrue(request.translate)
        XCTAssertTrue(request.prompt?.contains("TypeWhisper") == true)
        XCTAssertTrue(request.usedFileTranscriptionPipeline)
        XCTAssertTrue(plugin.selectedModelOverrides.contains("universal-3-5-pro"))
    }

    func testComparisonActivityPublishesRecorderAvailabilityAndRestoresItOnCompletion() async throws {
        let fixture = try await makeRestorableRecorderFixture(hasPersistedModel: true)
        let previousActivity = HistoryRetranscriptionActivity.recordID
        defer { HistoryRetranscriptionActivity.recordID = previousActivity }
        HistoryRetranscriptionActivity.recordID = nil
        let viewModel = fixture.viewModel
        var activity: [Bool] = []
        let subscription = viewModel.$isHistoryRetranscribing.sink { activity.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(viewModel.canToggleRecording)
        XCTAssertTrue(viewModel.canTranscribeRecording(fixture.recording))

        HistoryRetranscriptionActivity.recordID = UUID()
        XCTAssertTrue(viewModel.isHistoryRetranscribing)
        XCTAssertFalse(viewModel.canToggleRecording)
        XCTAssertFalse(viewModel.canTranscribeRecording(fixture.recording))
        let openedWhileBusy = makeViewModel(defaults: try makeDefaults())
        XCTAssertTrue(openedWhileBusy.isHistoryRetranscribing)
        XCTAssertFalse(openedWhileBusy.canToggleRecording)

        HistoryRetranscriptionActivity.recordID = nil
        XCTAssertTrue(viewModel.canToggleRecording)
        XCTAssertTrue(viewModel.canTranscribeRecording(fixture.recording))
        XCTAssertTrue(openedWhileBusy.canToggleRecording)
        XCTAssertEqual(activity, [false, true, false])
    }

    func testRecorderRetranscriptionIsAvailableForAutoUnloadedRestorableEngine() async throws {
        let fixture = try await makeRestorableRecorderFixture(hasPersistedModel: true)

        XCTAssertFalse(fixture.plugin.isConfigured)
        XCTAssertTrue(fixture.viewModel.canTranscribeRecording(fixture.recording))
        XCTAssertEqual(fixture.plugin.restoreCount, 0)
    }

    func testRecorderRetranscriptionRestoresAutoUnloadedEngineAndSavesTranscript() async throws {
        let fixture = try await makeRestorableRecorderFixture(hasPersistedModel: true)

        XCTAssertTrue(fixture.viewModel.canTranscribeRecording(fixture.recording))
        fixture.viewModel.transcribeRecording(fixture.recording)
        try await waitForRetranscriptionToFinish(fixture.viewModel)

        XCTAssertEqual(fixture.plugin.restoreCount, 1)
        XCTAssertTrue(fixture.plugin.isConfigured)
        XCTAssertEqual(
            try String(contentsOf: fixture.transcriptURL, encoding: .utf8),
            "restored transcription"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.failureURL.path))
    }

    func testRecorderRetranscriptionStaysDisabledAfterManualUnload() async throws {
        let fixture = try await makeRestorableRecorderFixture(hasPersistedModel: false)

        XCTAssertFalse(fixture.plugin.isConfigured)
        XCTAssertNotNil(fixture.plugin.selectedModelId, "A retained selection alone must not imply restorable state")
        XCTAssertFalse(fixture.viewModel.canTranscribeRecording(fixture.recording))
        XCTAssertEqual(fixture.plugin.restoreCount, 0)
    }

    func testRecorderRetranscriptionSurfacesMissingRestorableModelError() async throws {
        let restoreMessage = "Downloaded model is missing. Re-download it in Integrations."
        let fixture = try await makeRestorableRecorderFixture(
            restoreBehavior: .fails(restoreMessage),
            hasPersistedModel: true
        )

        XCTAssertTrue(fixture.viewModel.canTranscribeRecording(fixture.recording))
        fixture.viewModel.transcribeRecording(fixture.recording)
        try await waitForRetranscriptionToFinish(fixture.viewModel)

        let failure = try JSONDecoder().decode(
            AudioRecorderViewModel.RecordingTranscriptionFailure.self,
            from: Data(contentsOf: fixture.failureURL)
        )
        XCTAssertEqual(fixture.plugin.restoreCount, 1)
        XCTAssertFalse(fixture.plugin.isConfigured)
        XCTAssertEqual(failure.phase, .finalTranscription)
        XCTAssertTrue(failure.providerError.contains("Failed to load the selected model"))
        XCTAssertTrue(failure.providerError.contains(restoreMessage))
        XCTAssertTrue(fixture.viewModel.errorMessage?.contains(restoreMessage) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.transcriptURL.path))
    }

    func testRetranscriptionAudioLoadFailurePreservesExistingTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in throw AudioFileService.AudioFileError.unsupportedFormat }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcriptionFailure?.phase == .preparingFinalAudio
            }
        )

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .preparingFinalAudio)
        XCTAssertNil(viewModel.retranscribingRecordingURL)
    }

    func testCancelledRetranscriptionPreservesExistingTranscriptWithoutFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .cancellation)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(viewModel)

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureSidecarURL(for: audioURL).path))
        XCTAssertNil(viewModel.retranscribingRecordingURL)
        XCTAssertNil(viewModel.recordings.first?.transcriptionFailure)
    }

    func testRetranscriptionEngineFailurePreservesExistingTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .failure("provider unavailable"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcriptionFailure?.phase == .finalTranscription
            }
        )

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .finalTranscription)
        XCTAssertTrue(viewModel.recordings.first?.transcriptionFailure?.providerError.contains("provider unavailable") == true)
    }

    func testEmptyRetranscriptionPersistsFailureWithoutTranscript() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .empty)
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        try Data("audio".utf8).write(to: audioURL)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcriptionFailure?.phase == .emptyResult
            }
        )

        XCTAssertNil(viewModel.recordings.first?.transcript)
        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .emptyResult)
    }

    func testRetranscriptionSaveFailurePreservesExistingTranscriptAndRecordsFailure() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("replacement"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let failureURL = failureSidecarURL(for: audioURL)
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: transcriptURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: transcriptURL.path)
        }
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcriptionFailure?.phase == .savingTranscript
            }
        )

        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .savingTranscript)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureURL.path))
    }

    func testRetranscriptionMarkdownWriteFailureRestoresAllTranscriptFiles() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("replacement"))
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Meeting.wav")
        let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        let documentURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.json")
        let markdownURL = audioURL.deletingPathExtension().appendingPathExtension("transcript.md")
        let failureURL = failureSidecarURL(for: audioURL)
        let metadata = makeCalendarMeetingTranscriptMetadata(title: "Meeting")
        let originalDocument = RecordingTranscriptDocument(
            text: "keep me",
            calendarEvent: metadata
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let originalDocumentData = try encoder.encode(originalDocument)
        let originalMarkdown = RecordingTranscriptMarkdownRenderer.render(originalDocument)
        try Data("audio".utf8).write(to: audioURL)
        try "keep me".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try originalDocumentData.write(to: documentURL, options: .atomic)
        try originalMarkdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: markdownURL.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: markdownURL.path)
        }
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        viewModel.transcribeRecording(try XCTUnwrap(viewModel.recordings.first))
        try await waitForRetranscriptionToFinish(
            viewModel,
            recordingsSatisfy: {
                $0.recordings.first?.transcriptionFailure?.phase == .savingTranscript
            }
        )

        XCTAssertEqual(viewModel.recordings.first?.transcriptionFailure?.phase, .savingTranscript)
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), "keep me")
        XCTAssertEqual(try Data(contentsOf: documentURL), originalDocumentData)
        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), originalMarkdown)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureURL.path))
    }

    func testRetranscriptionRejectsConcurrentRetryAndRecordingStart() async throws {
        try preserveStandardDefaults()
        setupPluginManager()
        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let recordingsDirectory = makeTemporaryDirectory()
        let firstURL = recordingsDirectory.appendingPathComponent("First.wav")
        let secondURL = recordingsDirectory.appendingPathComponent("Second.wav")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        var continuation: CheckedContinuation<[Float], Never>?
        var loadCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in
                loadCount += 1
                return await withCheckedContinuation { continuation = $0 }
            }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 2)
        XCTAssertEqual(viewModel.recordings.count, 2)
        let first = try XCTUnwrap(viewModel.recordings.first)
        let second = try XCTUnwrap(viewModel.recordings.dropFirst().first)

        viewModel.transcribeRecording(first)
        for _ in 0..<20 where continuation == nil {
            await Task.yield()
        }
        XCTAssertNotNil(continuation)
        XCTAssertFalse(viewModel.canToggleRecording)
        XCTAssertFalse(viewModel.canTranscribeRecording(second))

        viewModel.transcribeRecording(second)
        XCTAssertEqual(loadCount, 1)

        viewModel.deleteRecording(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(viewModel.recordings.count, 2)

        do {
            _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
            XCTFail("Expected recording start to be rejected while retranscribing")
        } catch let error as AudioRecorderViewModel.RecorderAPIError {
            guard case .retranscribing = error else {
                return XCTFail("Expected retranscribing error, got \(error)")
            }
        }

        continuation?.resume(returning: [0.25, -0.25])
        try await waitForRetranscriptionToFinish(viewModel)
        XCTAssertTrue(viewModel.canToggleRecording)
    }

    func testRecorderRetranscriptionCopyIsLocalized() throws {
        for key in [
            "recorder.retranscribe",
            "recorder.retranscribing",
            "recorder.retranscribeConfirmation.title",
            "recorder.retranscribeConfirmation.message"
        ] {
            for language in ["de", "en", "ja", "zh-Hans"] {
                XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: language).isEmpty)
            }
        }
    }

    func testRecorderStopEntersFinalizingBeforeAudioFinalizationCompletes() async throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        let recordingsDirectory = makeTemporaryDirectory()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let gate = RecorderStopFinalizationGate()
        recorderService.stopRecordingOverride = { outputURL in
            try await gate.wait(outputURL: outputURL)
        }

        let viewModel = makeViewModel(defaults: defaults, recorderService: recorderService)
        viewModel.transcriptionEnabled = false
        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        viewModel.stopRecording()

        XCTAssertEqual(viewModel.state, .finalizing)
        XCTAssertFalse(viewModel.canToggleRecording)
        for _ in 0..<100 where !(await gate.hasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let finalizationStarted = await gate.hasStarted()
        XCTAssertTrue(finalizationStarted)

        await gate.resume()
        for _ in 0..<100 where viewModel.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.state, .idle)
    }

    // MARK: - Background final transcription (#1080)

    /// Back-to-back meetings: the next recording starts while the transcript of the
    /// one before is made. Transcripts run one at a time, in the order the recordings
    /// stopped, and each reports to its own API session exactly once.
    func testNextRecordingStartsWhileEarlierTranscriptsArePending() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        let announcements = RecorderAnnouncementLog()
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: marker,
            accessibilityAnnouncementService: announcements.service
        )
        var readyTexts: [String] = []
        var stoppedEvents = 0
        EventBus.shared.emissionObserverForTesting = { event in
            switch event {
            case .recorderTranscriptReady(let payload): readyTexts.append(payload.text)
            case .recordingStopped: stoppedEvents += 1
            default: break
            }
        }

        let first = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertTrue(viewModel.canToggleRecording)
        XCTAssertEqual(viewModel.apiRecorderSession(id: first)?.status, .finalizing)

        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertEqual(viewModel.apiRecorderSession(id: second)?.status, .recording)
        XCTAssertEqual(viewModel.apiRecorderSession(id: first)?.status, .finalizing)
        XCTAssertEqual(try viewModel.apiStopRecording(), second)
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }
        XCTAssertEqual(viewModel.pendingTranscriptions.map(\.status), [.transcribing, .waiting])
        XCTAssertTrue(viewModel.isTranscribing)
        let waitingCount = await gate.waitingCount
        XCTAssertEqual(waitingCount, 1, "The second transcript waits for the first")

        // Both recordings are listed right away, each with its place in the queue.
        try await waitForRecordingsToLoad(viewModel, count: 2)
        let firstItem = try XCTUnwrap(recording(of: first, in: viewModel))
        let secondItem = try XCTUnwrap(recording(of: second, in: viewModel))
        XCTAssertEqual(viewModel.transcriptionStatus(for: firstItem), .transcribing)
        XCTAssertEqual(viewModel.transcriptionStatus(for: secondItem), .waiting)

        await gate.finishNext(.text("first meeting"))
        let firstSession = try await waitForRecorderSession(viewModel, id: first, status: .completed)
        XCTAssertEqual(firstSession.text, "first meeting")
        XCTAssertEqual(viewModel.apiRecorderSession(id: second)?.status, .finalizing)
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        XCTAssertEqual(viewModel.pendingTranscriptions.map(\.status), [.transcribing])

        await gate.finishNext(.text("second meeting"))
        let secondSession = try await waitForRecorderSession(viewModel, id: second, status: .completed)
        XCTAssertEqual(secondSession.text, "second meeting")
        XCTAssertTrue(viewModel.pendingTranscriptions.isEmpty)
        XCTAssertFalse(viewModel.isTranscribing)

        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.1, 0.2])
        XCTAssertEqual(readyTexts, ["first meeting", "second meeting"])
        XCTAssertEqual(stoppedEvents, 2)
        for session in [firstSession, secondSession] {
            let audioURL = URL(fileURLWithPath: try XCTUnwrap(session.outputFile))
            let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), session.text)
        }
        // Started, stopped, started, stopped, then one "transcript saved" per recording.
        let messages = announcements.messages
        XCTAssertEqual(messages.count, 6, "\(messages)")
        if messages.count == 6 {
            XCTAssertEqual(messages[0], messages[2])
            XCTAssertEqual(messages[1], messages[3])
            XCTAssertEqual(messages[4], messages[5])
            XCTAssertNotEqual(messages[4], messages[1])
        }
    }

    /// A failed transcript fails only its own recording and API session.
    func testFailedTranscriptDoesNotAffectTheNextRecording() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        let viewModel = makeQueueViewModel(defaults: try makeDefaults(), modelManager: modelManager, marker: marker)

        let first = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }

        await gate.finishNext(.failure("HTTP 500: provider unavailable"))
        let failedSession = try await waitForRecorderSession(viewModel, id: first, status: .failed)
        XCTAssertTrue(failedSession.error?.contains("HTTP 500") == true)
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        XCTAssertEqual(viewModel.apiRecorderSession(id: second)?.status, .finalizing)

        await gate.finishNext(.text("second meeting"))
        let secondSession = try await waitForRecorderSession(viewModel, id: second, status: .completed)
        XCTAssertEqual(secondSession.text, "second meeting")
        XCTAssertNil(secondSession.error)

        let firstURL = URL(fileURLWithPath: try XCTUnwrap(failedSession.outputFile))
        let secondURL = URL(fileURLWithPath: try XCTUnwrap(secondSession.outputFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureSidecarURL(for: firstURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureSidecarURL(for: secondURL).path))
        try await waitForRecordingsToLoad(viewModel, count: 2) {
            $0.transcript != nil || $0.transcriptionFailure != nil
        }
        XCTAssertNotNil(try XCTUnwrap(recording(of: first, in: viewModel)).transcriptionFailure)
        XCTAssertEqual(try XCTUnwrap(recording(of: second, in: viewModel)).transcript, "second meeting")
    }

    /// Quitting with transcripts pending keeps the audio and lists the recordings as
    /// not transcribed, with the reason. A result that arrives afterwards changes nothing.
    func testQuittingWithPendingTranscriptsKeepsTheRecordingsWithoutTranscripts() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        let viewModel = makeQueueViewModel(defaults: try makeDefaults(), modelManager: modelManager, marker: marker)

        let first = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }
        let audioURLs = try [first, second].map {
            URL(fileURLWithPath: try XCTUnwrap(viewModel.apiRecorderSession(id: $0)?.outputFile))
        }

        viewModel.markPendingTranscriptionsInterrupted()

        XCTAssertTrue(viewModel.pendingTranscriptions.isEmpty)
        XCTAssertFalse(viewModel.isTranscribing)
        let interrupted = String(localized: "recorder.transcriptionInterruptedError")
        for audioURL in audioURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
            let transcriptURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
            let failure = try JSONDecoder().decode(
                AudioRecorderViewModel.RecordingTranscriptionFailure.self,
                from: Data(contentsOf: failureSidecarURL(for: audioURL))
            )
            XCTAssertEqual(failure.phase, .finalTranscription)
            XCTAssertEqual(failure.providerError, interrupted)
        }

        // The first transcript's result arrives after quitting. A later recording's
        // transcript starts only after that, and finishes after it.
        var readyTexts: [String] = []
        EventBus.shared.emissionObserverForTesting = { event in
            if case .recorderTranscriptReady(let payload) = event { readyTexts.append(payload.text) }
        }
        await gate.finishNext(.text("late transcript"))
        marker.withLock { $0 = 0.3 }
        let third = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the third transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("third meeting"))
        _ = try await waitForRecorderSession(viewModel, id: third, status: .completed)

        XCTAssertEqual(readyTexts, ["third meeting"])
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.1, 0.3], "The second transcript must not start after quitting")
        let firstTranscriptURL = audioURLs[0].deletingPathExtension().appendingPathExtension("txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstTranscriptURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureSidecarURL(for: audioURLs[0]).path))
    }

    /// While a queued transcript uses the engine, the next recording's live preview
    /// waits. The older transcript leaves the newer recording's preview alone.
    func testLivePreviewWaitsForAQueuedTranscriptOnTheSameEngine() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        var previewStarts = 0
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: marker,
            livePreviewStartObserver: { previewStarts += 1 }
        )
        viewModel.livePreviewEnabled = true
        var finalPreviews: [String] = []
        EventBus.shared.emissionObserverForTesting = { event in
            if case .partialTranscriptionUpdate(let payload) = event, payload.isFinal {
                finalPreviews.append(payload.text)
            }
        }

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(previewStarts, 1)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }

        marker.withLock { $0 = 0.2 }
        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(previewStarts, 1, "The preview must wait for the engine of the queued transcript")
        XCTAssertTrue(viewModel.isLivePreviewWaiting)
        viewModel.partialText = "second meeting so far"

        await gate.finishNext(.text("first meeting"))
        try await waitUntil("the preview started") { previewStarts == 2 }
        XCTAssertFalse(viewModel.isLivePreviewWaiting)
        XCTAssertEqual(viewModel.partialText, "second meeting so far")
        XCTAssertTrue(finalPreviews.isEmpty, "The first transcript must not end the second recording's preview")

        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("second meeting"))
        try await waitUntil("the second transcript is saved") { viewModel.pendingTranscriptions.isEmpty }
        XCTAssertEqual(viewModel.partialText, "second meeting")
        XCTAssertEqual(finalPreviews, ["second meeting"])
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.1, 0.2])
    }

    /// A preview on another engine starts right away; the transcripts still run one at a time.
    func testLivePreviewOnAnotherEngineStartsWhileATranscriptIsQueued() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate, providerIds: ["groq", "assemblyai"])
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        var previewStarts = 0
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: marker,
            livePreviewStartObserver: { previewStarts += 1 }
        )

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }

        viewModel.selectedEngine = "assemblyai"
        viewModel.livePreviewEnabled = true
        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        XCTAssertEqual(previewStarts, 1)
        XCTAssertFalse(viewModel.isLivePreviewWaiting)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }
        let waitingCount = await gate.waitingCount
        XCTAssertEqual(waitingCount, 1)

        await gate.finishNext(.text("first meeting"))
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("second meeting"))
        let secondSession = try await waitForRecorderSession(viewModel, id: second, status: .completed)
        XCTAssertEqual(secondSession.text, "second meeting")
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.1, 0.2])
    }

    /// A queued recording keeps its files and is transcribed once, with the speaker
    /// detection chosen when it stopped: it can be neither transcribed again nor
    /// deleted before its transcript is done.
    func testQueuedRecordingCanNeitherBeTranscribedAgainNorDeleted() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: OSAllocatedUnfairLock(initialState: Float(0.1))
        )
        viewModel.detectSpeakers = true
        var speakerInputs: [SpeakerRecordingInput] = []
        viewModel.speakerRecordIntake = { input in
            speakerInputs.append(input)
            return UUID()
        }

        let session = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the transcript started") { await gate.waitingCount == 1 }
        viewModel.detectSpeakers = false
        try await waitForRecordingsToLoad(viewModel, count: 1)
        let item = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertEqual(viewModel.transcriptionStatus(for: item), .transcribing)
        XCTAssertFalse(viewModel.canTranscribeRecording(item))

        viewModel.transcribeRecording(item)
        XCTAssertNil(viewModel.retranscribingRecordingURL)
        viewModel.deleteRecording(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(viewModel.recordings.count, 1)

        await gate.finishNext(.text("meeting notes"))
        let completed = try await waitForRecorderSession(viewModel, id: session, status: .completed)
        XCTAssertEqual(completed.text, "meeting notes")
        XCTAssertEqual(speakerInputs.count, 1)
        XCTAssertNotNil(speakerInputs.first?.recorderRecordingID)
        XCTAssertNil(viewModel.transcriptionStatus(for: item))
        XCTAssertTrue(viewModel.canTranscribeRecording(item))
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers.count, 1)
    }

    /// Back-to-back calendar meetings: the next meeting is recorded while the first is
    /// transcribed, and each transcript keeps its own meeting details.
    func testBackToBackCalendarMeetingsKeepTheirOwnMeetingDetails() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: OSAllocatedUnfairLock(initialState: Float(0.1))
        )
        let planning = makeCalendarMeetingTranscriptMetadata(eventIdentifier: "planning", title: "Planning")
        let review = makeCalendarMeetingTranscriptMetadata(eventIdentifier: "review", title: "Review")

        let planningHandle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "Planning",
            transcriptMetadata: planning
        )
        try viewModel.stopCalendarMeetingRecording(handle: planningHandle)
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        let reviewHandle = try await viewModel.startCalendarMeetingRecording(
            preferredBaseName: "Review",
            transcriptMetadata: review
        )
        try viewModel.stopCalendarMeetingRecording(handle: reviewHandle)
        try await waitUntil("the second meeting is queued") { viewModel.pendingTranscriptions.count == 2 }

        await gate.finishNext(.text("planning notes"))
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("review notes"))
        try await waitUntil("both transcripts are saved") { viewModel.pendingTranscriptions.isEmpty }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (handle, metadata, text) in [
            (planningHandle, planning, "planning notes"),
            (reviewHandle, review, "review notes")
        ] {
            let documentURL = handle.outputURL.deletingPathExtension().appendingPathExtension("transcript.json")
            let document = try decoder.decode(RecordingTranscriptDocument.self, from: Data(contentsOf: documentURL))
            XCTAssertEqual(document.calendarEvent, metadata)
            XCTAssertEqual(document.text, text)
        }
    }

    /// A queued transcript holds no audio once its file is complete; it reads the file
    /// when its turn comes, so back-to-back meetings do not pile up audio in memory.
    func testQueuedTranscriptsHoldNoAudioOnceTheirFilesAreComplete() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        var loadedFiles: [String] = []
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: marker,
            audioSamplesLoader: { url in
                loadedFiles.append(url.lastPathComponent)
                return Array(repeating: 0.7, count: Int(AudioRecorderService.transcriptionSampleRate))
            },
            // As long as the captured second of audio.
            recordingDurationReader: { _ in 1 }
        )

        let first = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }

        XCTAssertEqual(viewModel.queuedFinalTranscriptionSampleCounts, [0, 0])
        XCTAssertEqual(loadedFiles.count, 1, "The waiting transcript reads its file when its turn comes")

        await gate.finishNext(.text("first meeting"))
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("second meeting"))
        let firstSession = try await waitForRecorderSession(viewModel, id: first, status: .completed)
        let secondSession = try await waitForRecorderSession(viewModel, id: second, status: .completed)
        XCTAssertEqual(firstSession.text, "first meeting")
        XCTAssertEqual(secondSession.text, "second meeting")
        // The engine got each file's audio, not the captured audio.
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.7, 0.7])
        XCTAssertEqual(loadedFiles, [firstSession, secondSession].compactMap {
            $0.outputFile.map { URL(fileURLWithPath: $0).lastPathComponent }
        })
    }

    /// A file that fails the check at stop leaves its queued transcript the captured
    /// audio, which the transcript uses when the file cannot be read.
    func testQueuedTranscriptKeepsCapturedAudioWhenItsFileFailsTheCheck() async throws {
        try preserveStandardDefaults()
        let gate = RecorderTranscriptionGate()
        setupGatedPluginManager(gate: gate)
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let marker = OSAllocatedUnfairLock(initialState: Float(0.1))
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let viewModel = makeQueueViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            marker: marker,
            audioSamplesLoader: { _ in throw AudioFileService.AudioFileError.conversionFailed("truncated file") },
            // The first file cannot be opened, the second has no audio.
            recordingDurationReader: { _ in
                let check = checks.withLock { count in
                    count += 1
                    return count
                }
                if check == 1 { throw AudioFileService.AudioFileError.unsupportedFormat }
                return 0
            }
        )
        let capturedSampleCount = Int(AudioRecorderService.transcriptionSampleRate)

        let first = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the first transcript started") { await gate.waitingCount == 1 }
        marker.withLock { $0 = 0.2 }
        let second = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()
        try await waitUntil("the second recording is queued") { viewModel.pendingTranscriptions.count == 2 }

        XCTAssertEqual(viewModel.queuedFinalTranscriptionSampleCounts, [capturedSampleCount, capturedSampleCount])

        await gate.finishNext(.text("first meeting"))
        try await waitUntil("the second transcript started") { await gate.waitingCount == 1 }
        await gate.finishNext(.text("second meeting"))
        let firstSession = try await waitForRecorderSession(viewModel, id: first, status: .completed)
        let secondSession = try await waitForRecorderSession(viewModel, id: second, status: .completed)
        XCTAssertEqual(firstSession.text, "first meeting")
        XCTAssertEqual(secondSession.text, "second meeting")
        let startedMarkers = await gate.startedMarkers
        XCTAssertEqual(startedMarkers, [0.1, 0.2], "Each transcript used its own captured audio")
    }

    /// A file that was complete at stop but cannot be read when its turn comes leaves
    /// the recording with its audio, listed as not transcribed, to be transcribed again.
    func testCompleteFileThatCannotBeReadLaterLeavesTheRecordingNotTranscribed() async throws {
        try preserveStandardDefaults()
        setupPluginManager(groqBehavior: .success("not from this recording"))
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: makeTemporaryDirectory()),
            audioSamplesLoader: { _ in throw AudioFileService.AudioFileError.fileNotFound },
            recordingDurationReader: { _ in 1 }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .failed)
        XCTAssertTrue(session.error?.contains("File not found") == true, session.error ?? "no error")
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(session.outputFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureSidecarURL(for: audioURL).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: audioURL.deletingPathExtension().appendingPathExtension("txt").path
        ))
        let plugin = try XCTUnwrap(
            PluginManager.shared.transcriptionEngine(for: "groq") as? AudioRecorderMockTranscriptionPlugin
        )
        XCTAssertNil(plugin.lastRequest, "The engine never gets audio the job could not read")

        try await waitForRecordingsToLoad(viewModel, count: 1) { $0.transcriptionFailure != nil }
        let recording = try XCTUnwrap(viewModel.recordings.first)
        XCTAssertNil(recording.transcript)
        XCTAssertEqual(recording.transcriptionFailure?.phase, .preparingFinalAudio)
        XCTAssertTrue(viewModel.pendingTranscriptions.isEmpty)
        XCTAssertTrue(viewModel.canTranscribeRecording(recording), "The recording can be transcribed again")
    }

    func testFinalizedFileCheckAllowsOnlyASmallShortfall() {
        func isComplete(_ fileDuration: TimeInterval, of capturedDuration: TimeInterval) -> Bool {
            AudioRecorderViewModel.finalizedFileIsComplete(fileDuration: fileDuration, capturedDuration: capturedDuration)
        }
        XCTAssertTrue(isComplete(10, of: 10))
        XCTAssertTrue(isComplete(11, of: 10), "A longer file holds the whole recording")
        XCTAssertTrue(isComplete(9.1, of: 10), "Up to a second shorter")
        XCTAssertFalse(isComplete(8.8, of: 10))
        XCTAssertTrue(isComplete(3_540, of: 3_600), "Up to 2 % of a long recording shorter")
        XCTAssertFalse(isComplete(3_500, of: 3_600))
        XCTAssertFalse(isComplete(0, of: 0), "A file without audio")
        XCTAssertFalse(isComplete(.nan, of: 10))
        XCTAssertFalse(isComplete(.infinity, of: 10))
    }

    func testRecordingDurationReaderReadsTheFileHeader() async throws {
        let directory = makeTemporaryDirectory()
        let wavURL = directory.appendingPathComponent("Meeting.wav")
        try writePCMFile(at: wavURL, frameCount: 72_000, sampleRate: 48_000, channelCount: 2, sample: 0.25)
        let wavDuration = try await AudioRecorderViewModel.readRecordingDuration(wavURL)
        XCTAssertEqual(wavDuration, 1.5, accuracy: 0.001)

        let m4aURL = directory.appendingPathComponent("Meeting.m4a")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
            buffer.frameLength = 96_000
            let file = try AVAudioFile(forWriting: m4aURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            try file.write(from: buffer)
        }
        let m4aDuration = try await AudioRecorderViewModel.readRecordingDuration(m4aURL)
        XCTAssertEqual(m4aDuration, 2, accuracy: 0.05)

        let placeholderURL = directory.appendingPathComponent("Placeholder.wav")
        try Data("recorded".utf8).write(to: placeholderURL)
        do {
            _ = try await AudioRecorderViewModel.readRecordingDuration(placeholderURL)
            XCTFail("A file that is not audio has no length")
        } catch {}
    }

    /// A live transcript's speaker record reads the complete file when its turn comes.
    func testLiveTranscriptSpeakerRecordReadsTheCompleteFile() async throws {
        try preserveStandardDefaults()
        let livePlugin = setupAnsweringLivePlugin()
        let modelManager = ModelManagerService()
        modelManager.selectProvider(livePlugin.providerId)
        let fileSamples = Array(repeating: Float(0.3), count: Int(AudioRecorderService.transcriptionSampleRate * 6))
        let viewModel = try makeLiveSpeakerViewModel(
            modelManager: modelManager,
            audioSamplesLoader: { _ in fileSamples }
        )
        var speakerSamples: [[Float]] = []
        viewModel.speakerRecordIntake = { input in
            speakerSamples.append(input.samples)
            return UUID()
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        try await waitUntil("the live session started") { livePlugin.liveSessionCreateCount == 1 }
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "live meeting notes")
        XCTAssertEqual(livePlugin.batchTranscriptionCount, 0, "The live session's result is the transcript")
        XCTAssertEqual(speakerSamples, [fileSamples])
    }

    /// A live transcript is saved when its file cannot be read for the speaker record;
    /// only the speaker record is left out, and transcribing the recording again adds it.
    func testLiveTranscriptIsSavedWhenItsFileCannotBeReadForTheSpeakerRecord() async throws {
        try preserveStandardDefaults()
        let livePlugin = setupAnsweringLivePlugin()
        let modelManager = ModelManagerService()
        modelManager.selectProvider(livePlugin.providerId)
        let viewModel = try makeLiveSpeakerViewModel(
            modelManager: modelManager,
            audioSamplesLoader: { _ in throw AudioFileService.AudioFileError.fileNotFound }
        )
        var speakerInputs = 0
        viewModel.speakerRecordIntake = { _ in
            speakerInputs += 1
            return UUID()
        }

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        try await waitUntil("the live session started") { livePlugin.liveSessionCreateCount == 1 }
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "live meeting notes")
        XCTAssertEqual(speakerInputs, 0)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(session.outputFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureSidecarURL(for: audioURL).path))
    }

    /// Without a speaker record, a live transcript needs no audio, so nothing is read.
    func testLiveTranscriptWithoutSpeakerRecordReadsNoAudio() async throws {
        try preserveStandardDefaults()
        let livePlugin = setupAnsweringLivePlugin()
        let modelManager = ModelManagerService()
        modelManager.selectProvider(livePlugin.providerId)
        var loads = 0
        let viewModel = try makeLiveSpeakerViewModel(
            modelManager: modelManager,
            audioSamplesLoader: { _ in
                loads += 1
                return []
            }
        )
        viewModel.detectSpeakers = false

        let sessionID = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)
        try await waitUntil("the live session started") { livePlugin.liveSessionCreateCount == 1 }
        _ = try viewModel.apiStopRecording()

        let session = try await waitForRecorderSession(viewModel, id: sessionID, status: .completed)
        XCTAssertEqual(session.text, "live meeting notes")
        XCTAssertEqual(loads, 0)
    }

    func testRecorderTranscriptionQueueCopyIsLocalized() throws {
        for key in [
            "recorder.transcriptionQueue",
            "recorder.transcriptionWaiting",
            "recorder.livePreviewWaitsForQueue",
            "recorder.transcriptionInterruptedError"
        ] {
            for language in ["de", "en", "ja", "zh-Hans"] {
                XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: language).isEmpty)
            }
        }
    }

    func testRecorderFinalizationStreamsMixedAudioAcrossChunkBoundaries() async throws {
        let directory = makeTemporaryDirectory()
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let outputURL = directory.appendingPathComponent("mixed.wav")
        let outputFrameCount = Int(AudioRecorderService.finalizationChunkFrameCount) * 3 + 137
        let micFrameCount = Int(
            (Double(outputFrameCount) * 44_100 / 48_000).rounded(.up)
        )

        try writePCMFile(
            at: micURL,
            frameCount: micFrameCount,
            sampleRate: 44_100,
            channelCount: 1,
            sample: 0.1
        )
        try writePCMFile(
            at: systemURL,
            frameCount: outputFrameCount,
            sampleRate: 48_000,
            channelCount: 2,
            sample: 0.2
        )

        let recorderService = AudioRecorderService()
        let resultURL = await recorderService.finalizeRecording(.init(
            finalOutputURL: outputURL,
            micTempURL: micURL,
            systemTempURL: systemURL,
            outputFormat: .wav,
            trackMode: .mixed,
            micDuckingMode: .aggressive,
            transcriptionSamples: [],
            usesFinalizationOverride: false
        ))

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))

        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertLessThanOrEqual(abs(Int(outputFile.length) - outputFrameCount), 1)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFile.processingFormat,
            frameCapacity: AVAudioFrameCount(outputFile.length)
        ) else {
            return XCTFail("Could not allocate mixed-audio verification buffer")
        }
        try outputFile.read(into: outputBuffer)
        let leftChannel = try XCTUnwrap(outputBuffer.floatChannelData?[0])
        let rightChannel = try XCTUnwrap(outputBuffer.floatChannelData?[1])
        XCTAssertEqual(leftChannel[0], 0.3, accuracy: 0.01)
        XCTAssertEqual(rightChannel[0], 0.3, accuracy: 0.01)
        let chunkSize = Int(AudioRecorderService.finalizationChunkFrameCount)
        for boundary in [chunkSize, chunkSize * 2] {
            XCTAssertEqual(leftChannel[boundary - 1], leftChannel[boundary], accuracy: 0.002)
            XCTAssertEqual(rightChannel[boundary - 1], rightChannel[boundary], accuracy: 0.002)
            XCTAssertLessThan(leftChannel[boundary], 0.23)
            XCTAssertLessThan(rightChannel[boundary], 0.23)
        }
        XCTAssertEqual(leftChannel[outputFrameCount - 1], 0.218, accuracy: 0.002)
        XCTAssertEqual(rightChannel[outputFrameCount - 1], 0.218, accuracy: 0.002)
    }

    func testRecorderFinalizationStreamsSingleSourceM4AConversion() async throws {
        let directory = makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("mic.wav")
        let outputURL = directory.appendingPathComponent("recording.m4a")
        let frameCount = Int(AudioRecorderService.finalizationChunkFrameCount) * 3 + 137
        try writePCMFile(
            at: sourceURL,
            frameCount: frameCount,
            sampleRate: 48_000,
            channelCount: 2,
            sample: 0.1
        )

        let recorderService = AudioRecorderService()
        let resultURL = await recorderService.finalizeRecording(.init(
            finalOutputURL: outputURL,
            micTempURL: sourceURL,
            systemTempURL: nil,
            outputFormat: .m4a,
            trackMode: .mixed,
            micDuckingMode: .off,
            transcriptionSamples: [],
            usesFinalizationOverride: false
        ))

        XCTAssertEqual(resultURL, outputURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        let outputFile = try AVAudioFile(forReading: outputURL)
        let outputDuration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
        XCTAssertEqual(outputDuration, Double(frameCount) / 48_000, accuracy: 0.05)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService = ModelManagerService(),
        recorderService: AudioRecorderService? = nil,
        dictionaryService: DictionaryService? = nil,
        audioDeviceService: AudioDeviceService = AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
        audioSamplesLoader: AudioRecorderViewModel.AudioSamplesLoader? = nil,
        recordingDurationReader: AudioRecorderViewModel.RecordingDurationReader? = nil,
        speechRegionDetector: any SpeechRegionDetecting = WholeRecordingSpeechDetector(),
        recordingsLoader: AudioRecorderViewModel.RecordingsLoader? = nil,
        recorderCompletionsLoader: AudioRecorderViewModel.RecorderCompletionsLoader? = nil,
        trash: URL? = nil,
        livePreviewStartObserver: (() -> Void)? = nil,
        accessibilityAnnouncementService: AccessibilityAnnouncementService? = nil
    ) -> AudioRecorderViewModel {
        setupEventBus()
        let resolvedRecorderService = recorderService ?? {
            let service = AudioRecorderService()
            service.recordingsDirectoryOverride = makeTemporaryDirectory()
            return service
        }()
        return AudioRecorderViewModel(
            recorderService: resolvedRecorderService,
            modelManager: modelManager,
            dictionaryService: dictionaryService ?? DictionaryService(appSupportDirectory: makeTemporaryDirectory()),
            audioDeviceService: audioDeviceService,
            defaults: defaults,
            audioSamplesLoader: audioSamplesLoader,
            recordingDurationReader: recordingDurationReader,
            speechRegionDetector: speechRegionDetector,
            recordingsLoader: recordingsLoader,
            recorderCompletionsLoader: recorderCompletionsLoader,
            recordingFileTrasher: TestSupport.recordingFileTrasher(into: trash ?? makeTemporaryDirectory()),
            livePreviewStartObserver: livePreviewStartObserver,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
    }

    private func writePCMFile(
        at url: URL,
        frameCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        sample: Float
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Could not allocate recorder finalization fixture")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(channelCount) {
            buffer.floatChannelData?[channel].update(repeating: sample, count: frameCount)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func makeFinalTranscriptionViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService,
        recordingsDirectory: URL? = nil,
        samples: [Float] = Array(repeating: 0.25, count: Int(AudioRecorderService.transcriptionSampleRate)),
        speechRegionDetector: any SpeechRegionDetecting = WholeRecordingSpeechDetector()
    ) -> AudioRecorderViewModel {
        let recorderService = makeRecorderService(
            recordingsDirectory: recordingsDirectory ?? makeTemporaryDirectory(),
            samples: samples
        )
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            speechRegionDetector: speechRegionDetector
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false
        return viewModel
    }

    private func makeRecorderService(
        recordingsDirectory: URL,
        outputURL: URL? = nil,
        samples: [Float] = Array(repeating: 0.25, count: Int(AudioRecorderService.transcriptionSampleRate))
    ) -> AudioRecorderService {
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = recordingsDirectory
        recorderService.startRecordingOverride = { _, _, _, proposedOutputURL, _ in
            let resolvedOutputURL = outputURL ?? proposedOutputURL
            try FileManager.default.createDirectory(
                at: resolvedOutputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("placeholder".utf8).write(to: resolvedOutputURL)
            return resolvedOutputURL
        }
        recorderService.stopRecordingOverride = { resolvedOutputURL in
            try Data("recorded".utf8).write(to: resolvedOutputURL)
            return resolvedOutputURL
        }
        recorderService.currentBufferOverride = { samples }
        return recorderService
    }

    /// A Recorder whose recordings hold `marker` in every sample, so the engine can
    /// tell them apart.
    private func makeQueueViewModel(
        defaults: UserDefaults,
        modelManager: ModelManagerService,
        marker: OSAllocatedUnfairLock<Float>,
        audioSamplesLoader: AudioRecorderViewModel.AudioSamplesLoader? = nil,
        recordingDurationReader: AudioRecorderViewModel.RecordingDurationReader? = nil,
        livePreviewStartObserver: (() -> Void)? = nil,
        accessibilityAnnouncementService: AccessibilityAnnouncementService? = nil
    ) -> AudioRecorderViewModel {
        let recorderService = makeRecorderService(recordingsDirectory: makeTemporaryDirectory())
        recorderService.currentBufferOverride = {
            Array(repeating: marker.withLock { $0 }, count: Int(AudioRecorderService.transcriptionSampleRate))
        }
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            audioSamplesLoader: audioSamplesLoader,
            recordingDurationReader: recordingDurationReader,
            livePreviewStartObserver: livePreviewStartObserver,
            accessibilityAnnouncementService: accessibilityAnnouncementService
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = false
        return viewModel
    }

    /// A Recorder with live preview and speaker records. Its six captured seconds
    /// are matched by a complete file.
    private func makeLiveSpeakerViewModel(
        modelManager: ModelManagerService,
        audioSamplesLoader: @escaping AudioRecorderViewModel.AudioSamplesLoader
    ) throws -> AudioRecorderViewModel {
        let captureSamples = Array(repeating: Float(0.25), count: Int(AudioRecorderService.transcriptionSampleRate * 6))
        let viewModel = makeViewModel(
            defaults: try makeDefaults(),
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: makeTemporaryDirectory(), samples: captureSamples),
            audioSamplesLoader: audioSamplesLoader,
            recordingDurationReader: { _ in 6 }
        )
        viewModel.transcriptionEnabled = true
        viewModel.livePreviewEnabled = true
        viewModel.detectSpeakers = true
        return viewModel
    }

    /// The mock engines, and a live engine whose session answers all audio.
    private func setupAnsweringLivePlugin() -> AudioRecorderAnsweringLivePlugin {
        setupPluginManager()
        let livePlugin = AudioRecorderAnsweringLivePlugin()
        PluginManager.shared.loadedPlugins.append(LoadedPlugin(
            manifest: PluginManifest(
                id: AudioRecorderAnsweringLivePlugin.pluginId,
                name: AudioRecorderAnsweringLivePlugin.pluginName,
                version: "1.0.0",
                principalClass: "AudioRecorderAnsweringLivePlugin"
            ),
            instance: livePlugin,
            bundle: Bundle.main,
            sourceURL: makeTemporaryDirectory(),
            isEnabled: true
        ))
        return livePlugin
    }

    /// Engines whose transcriptions wait for `gate`.
    private func setupGatedPluginManager(gate: RecorderTranscriptionGate, providerIds: [String] = ["groq"]) {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }
        // A test that stops early must not leave transcriptions waiting.
        addTeardownBlock {
            await gate.finishAll(.failure("The test ended"))
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = providerIds.map { providerId in
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.gated.\(providerId)",
                    name: providerId,
                    version: "1.0.0",
                    principalClass: "RecorderGatedTranscriptionPlugin"
                ),
                instance: RecorderGatedTranscriptionPlugin(providerId: providerId, gate: gate),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        }
        PluginManager.shared = pluginManager
    }

    private func recording(
        of sessionID: UUID,
        in viewModel: AudioRecorderViewModel
    ) -> AudioRecorderViewModel.RecordingItem? {
        guard let outputFile = viewModel.apiRecorderSession(id: sessionID)?.outputFile else { return nil }
        let fileName = URL(fileURLWithPath: outputFile).lastPathComponent
        return viewModel.recordings.first { $0.fileName == fileName }
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting until \(description)", file: file, line: line)
    }

    private func failureSidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("transcription-failure.json")
    }

    private func waitForRetranscriptionToFinish(
        _ viewModel: AudioRecorderViewModel,
        recordingsSatisfy: (AudioRecorderViewModel) -> Bool = { _ in true },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            // The operation flag is cleared before loadRecordings() publishes its asynchronous refresh.
            if viewModel.retranscribingRecordingURL == nil, recordingsSatisfy(viewModel) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Recorder retranscription or recording reload did not finish", file: file, line: line)
    }

    private func waitForRecordingsToLoad(
        _ viewModel: AudioRecorderViewModel,
        count: Int,
        recordingsSatisfy: (AudioRecorderViewModel.RecordingItem) -> Bool = { _ in true },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if viewModel.recordings.count == count,
               viewModel.recordings.allSatisfy(recordingsSatisfy) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(
            "Recorder library did not load \(count) items. Current count: \(viewModel.recordings.count)",
            file: file,
            line: line
        )
    }

    private func livePreviewStartCount(
        transcriptionEnabled: Bool,
        livePreviewEnabled: Bool
    ) async throws -> Int {
        let defaults = try makeDefaults()
        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = makeTemporaryDirectory()
        recorderService.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        let modelManager = ModelManagerService()
        modelManager.selectProvider("groq")
        var startCount = 0
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: recorderService,
            livePreviewStartObserver: { startCount += 1 }
        )
        viewModel.transcriptionEnabled = transcriptionEnabled
        viewModel.livePreviewEnabled = livePreviewEnabled

        _ = try await viewModel.apiStartRecording(micEnabled: true, systemAudioEnabled: false)

        return startCount
    }

    private func waitForRecorderSession(
        _ viewModel: AudioRecorderViewModel,
        id: UUID,
        status: AudioRecorderViewModel.RecorderAPISessionStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AudioRecorderViewModel.RecorderAPISessionSnapshot {
        for _ in 0..<40 {
            if let session = viewModel.apiRecorderSession(id: id), session.status == status {
                return session
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let session = viewModel.apiRecorderSession(id: id)
        XCTFail("Recorder session \(id) did not reach \(status.rawValue). Current status: \(session?.status.rawValue ?? "missing")", file: file, line: line)
        return try XCTUnwrap(session, file: file, line: line)
    }

    private func makeRestorableRecorderFixture(
        restoreBehavior: AudioRecorderRestorableTranscriptionPlugin.RestoreBehavior = .succeeds,
        hasPersistedModel: Bool
    ) async throws -> RestorableRecorderFixture {
        try preserveStandardDefaults(additionalKeys: [
            AudioRecorderRestorableTranscriptionPlugin.loadedModelDefaultsKey
        ])
        let plugin = setupRestorablePluginManager(restoreBehavior: restoreBehavior)
        if hasPersistedModel {
            UserDefaults.standard.set(
                AudioRecorderRestorableTranscriptionPlugin.modelId,
                forKey: AudioRecorderRestorableTranscriptionPlugin.loadedModelDefaultsKey
            )
        }

        let defaults = try makeDefaults()
        let modelManager = ModelManagerService()
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 1,
            busyAttempts: 1,
            pollInterval: .milliseconds(1)
        )
        modelManager.selectProvider(plugin.providerId)

        let recordingsDirectory = makeTemporaryDirectory()
        let audioURL = recordingsDirectory.appendingPathComponent("Restorable.wav")
        try Data("audio".utf8).write(to: audioURL)
        let viewModel = makeViewModel(
            defaults: defaults,
            modelManager: modelManager,
            recorderService: makeRecorderService(recordingsDirectory: recordingsDirectory),
            audioSamplesLoader: { _ in [0.25, -0.25] }
        )
        viewModel.loadRecordings()
        try await waitForRecordingsToLoad(viewModel, count: 1)

        return RestorableRecorderFixture(
            viewModel: viewModel,
            plugin: plugin,
            recording: try XCTUnwrap(viewModel.recordings.first),
            transcriptURL: audioURL.deletingPathExtension().appendingPathExtension("txt"),
            failureURL: failureSidecarURL(for: audioURL)
        )
    }

    private func setupEventBus() {
        let previousEventBus: EventBus? = EventBus.shared
        EventBus.shared = EventBus()
        addTeardownBlock {
            EventBus.shared = previousEventBus
        }
    }

    private func setupPluginManager(
        groqBehavior: AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior = .success("mock transcription"),
        assemblyAIBehavior: AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior = .success("mock transcription")
    ) {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.groq",
                    name: "Groq",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "groq",
                    displayName: "Groq",
                    models: [
                        PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
                        PluginModelInfo(id: "whisper-small", displayName: "Whisper Small")
                    ],
                    selectedModelId: "whisper-large-v3",
                    behavior: groqBehavior
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.assemblyai",
                    name: "AssemblyAI",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "assemblyai",
                    displayName: "AssemblyAI",
                    models: [
                        PluginModelInfo(id: "universal-3-5-pro", displayName: "Universal-3.5 Pro"),
                        PluginModelInfo(id: "universal-2", displayName: "Universal-2")
                    ],
                    selectedModelId: "universal-2",
                    behavior: assemblyAIBehavior
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
    }

    private func setupDeepgramPluginManager(globalModel: String) -> DeepgramPlugin {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let deepgram = DeepgramPlugin()
        deepgram.selectModel(globalModel)
        let appSupportDirectory = makeTemporaryDirectory()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: DeepgramPlugin.pluginId,
                    name: DeepgramPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "DeepgramPlugin"
                ),
                instance: deepgram,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
        return deepgram
    }

    private func setupRestorablePluginManager(
        restoreBehavior: AudioRecorderRestorableTranscriptionPlugin.RestoreBehavior
    ) -> AudioRecorderRestorableTranscriptionPlugin {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let plugin = AudioRecorderRestorableTranscriptionPlugin(restoreBehavior: restoreBehavior)
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: AudioRecorderRestorableTranscriptionPlugin.pluginId,
                    name: AudioRecorderRestorableTranscriptionPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "AudioRecorderRestorableTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
        return plugin
    }

    private func setupWhisperPluginManager(
        behavior: AudioRecorderMockTranscriptionPlugin.TranscriptionBehavior
    ) -> AudioRecorderMockTranscriptionPlugin {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let plugin = AudioRecorderMockTranscriptionPlugin(
            providerId: "whisper",
            displayName: "WhisperKit",
            models: [
                PluginModelInfo(
                    id: "openai_whisper-large-v3",
                    displayName: "Whisper Large V3"
                )
            ],
            selectedModelId: "openai_whisper-large-v3",
            behavior: behavior
        )
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.whisperkit",
                    name: "WhisperKit",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
        return plugin
    }

    private func preserveStandardDefaults(additionalKeys: [String] = []) throws {
        let keys = Array(Set([
            UserDefaultsKeys.selectedEngine,
            UserDefaultsKeys.selectedModelId,
            UserDefaultsKeys.selectedInputDeviceUID,
            UserDefaultsKeys.inputDevicePriorityList
        ] + additionalKeys))
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        addTeardownBlock {
            for key in keys {
                if let value = originals[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "AudioRecorderViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private final class AudioRecorderRestorableTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, PluginSettingsActivityReporting, @unchecked Sendable {
    enum RestoreBehavior: Sendable {
        case succeeds
        case fails(String)
    }

    private struct State {
        var isConfigured = false
        var currentSettingsActivity: PluginSettingsActivity?
        var restoreCount = 0
    }

    static let pluginId = "com.typewhisper.mock.audio-recorder-restorable"
    static let pluginName = "Audio Recorder Restorable Mock"
    static let modelId = "restorable-model"
    static let loadedModelDefaultsKey = "plugin.\(pluginId).loadedModel"

    let providerId = "recorder-restorable"
    let providerDisplayName = "Recorder Restorable"
    let transcriptionModels = [PluginModelInfo(id: modelId, displayName: "Restorable Model")]
    var selectedModelId: String? { Self.modelId }
    var supportsTranslation = false
    var isConfigured: Bool { stateLock.withLock { state.isConfigured } }
    var currentSettingsActivity: PluginSettingsActivity? {
        stateLock.withLock { state.currentSettingsActivity }
    }
    var restoreCount: Int { stateLock.withLock { state.restoreCount } }

    private let restoreBehavior: RestoreBehavior
    private let stateLock = NSLock()
    private var state = State()

    required override init() {
        self.restoreBehavior = .succeeds
        super.init()
    }

    init(restoreBehavior: RestoreBehavior) {
        self.restoreBehavior = restoreBehavior
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    @objc func triggerRestoreModel() {
        stateLock.withLock {
            state.restoreCount += 1
            switch restoreBehavior {
            case .succeeds:
                state.isConfigured = true
                state.currentSettingsActivity = nil
            case .fails(let message):
                state.isConfigured = false
                state.currentSettingsActivity = PluginSettingsActivity(message: message, isError: true)
            }
        }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard isConfigured else { throw PluginTranscriptionError.notConfigured }
        return PluginTranscriptionResult(text: "restored transcription", detectedLanguage: language)
    }
}

/// Its live session drops on every append, and batch transcription fails too.
private final class AudioRecorderDroppingLivePlugin: NSObject, LiveTranscriptionCapablePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.dropping-live"
    static let pluginName = "Dropping Live"

    var providerId: String { "dropping-live" }
    var providerDisplayName: String { "Dropping Live" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "live", displayName: "Live")] }
    var selectedModelId: String? { "live" }
    var supportsTranslation: Bool { false }
    private let counts = OSAllocatedUnfairLock(initialState: (sessions: 0, batch: 0))

    var liveSessionCreateCount: Int { counts.withLock { $0.sessions } }
    var batchTranscriptionCount: Int { counts.withLock { $0.batch } }

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        counts.withLock { $0.batch += 1 }
        throw PluginTranscriptionError.networkError("The Internet connection appears to be offline.")
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        counts.withLock { $0.sessions += 1 }
        return DroppingSession()
    }

    private actor DroppingSession: LiveTranscriptionSession {
        func appendAudio(samples: [Float]) async throws {
            throw PluginTranscriptionError.networkError("Socket is not connected")
        }

        func finish() async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "", detectedLanguage: nil)
        }

        func cancel() async {}
    }
}

/// A live session that stays connected but reports text only for its first audio, and
/// finishes with that text.
private final class AudioRecorderStallingLivePlugin: NSObject, LiveTranscriptionCapablePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.stalling-live"
    static let pluginName = "Stalling Live"

    var providerId: String { "stalling-live" }
    var providerDisplayName: String { "Stalling Live" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "live", displayName: "Live")] }
    var selectedModelId: String? { "live" }
    var supportsTranslation: Bool { false }
    private let state = OSAllocatedUnfairLock(initialState: (sessions: 0, batchSamples: [Float]()))

    var liveSessionCreateCount: Int { state.withLock { $0.sessions } }
    var batchTranscriptionSamples: [Float] { state.withLock { $0.batchSamples } }

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        state.withLock { $0.batchSamples = audio.samples }
        return PluginTranscriptionResult(text: "complete transcript", detectedLanguage: language)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        state.withLock { $0.sessions += 1 }
        return StallingSession(onProgress: onProgress)
    }

    private actor StallingSession: LiveTranscriptionSession {
        private let onProgress: @Sendable (String) -> Bool
        private var reportedText = false

        init(onProgress: @Sendable @escaping (String) -> Bool) {
            self.onProgress = onProgress
        }

        func appendAudio(samples: [Float]) async throws {
            guard !reportedText else { return }
            reportedText = true
            _ = onProgress("words before the stall")
        }

        func finish() async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "words before the stall", detectedLanguage: "en")
        }

        func cancel() async {}
    }
}

/// A live session that answers all audio and finishes with more text than its preview.
private final class AudioRecorderAnsweringLivePlugin: NSObject, LiveTranscriptionCapablePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.answering-live"
    static let pluginName = "Answering Live"

    var providerId: String { "answering-live" }
    var providerDisplayName: String { "Answering Live" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "live", displayName: "Live")] }
    var selectedModelId: String? { "live" }
    var supportsTranslation: Bool { false }
    private let counts = OSAllocatedUnfairLock(initialState: (sessions: 0, batch: 0))

    var liveSessionCreateCount: Int { counts.withLock { $0.sessions } }
    var batchTranscriptionCount: Int { counts.withLock { $0.batch } }

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        counts.withLock { $0.batch += 1 }
        return PluginTranscriptionResult(text: "batch transcript", detectedLanguage: language)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        counts.withLock { $0.sessions += 1 }
        return AnsweringSession(onProgress: onProgress)
    }

    private actor AnsweringSession: LiveTranscriptionSession {
        private let onProgress: @Sendable (String) -> Bool

        init(onProgress: @Sendable @escaping (String) -> Bool) {
            self.onProgress = onProgress
        }

        func appendAudio(samples: [Float]) async throws {
            _ = onProgress("live meeting")
        }

        func finish() async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "live meeting notes", detectedLanguage: "en")
        }

        func cancel() async {}
    }
}

private final class AudioRecorderMockTranscriptionPlugin: NSObject, SourceProgressTranscriptionEnginePlugin, @unchecked Sendable {
    struct Request: Sendable {
        let language: String?
        let translate: Bool
        let prompt: String?
        let audioSampleCount: Int
        let firstAudioSample: Float?
        let usedFileTranscriptionPipeline: Bool
    }

    enum TranscriptionBehavior {
        case success(String)
        case empty
        case failure(String)
        case cancellation
        case conditionedShortFallbackComplete(shortText: String, completeText: String)
        case conditionedShortFallbackFailure
        case timed(text: String, segments: [PluginTranscriptionSegment], words: [PluginWordTiming])
    }

    static let pluginId = "com.typewhisper.mock.audio-recorder"
    static let pluginName = "Audio Recorder Mock"

    let providerId: String
    let providerDisplayName: String
    let transcriptionModels: [PluginModelInfo]
    var selectedModelId: String?
    var isConfigured = true
    var supportsTranslation = true
    private let behavior: TranscriptionBehavior
    private(set) var lastRequest: Request?
    private(set) var requests: [Request] = []
    private(set) var selectedModelOverrides: [String] = []

    required override init() {
        self.providerId = "mock"
        self.providerDisplayName = "Mock"
        self.transcriptionModels = []
        self.selectedModelId = nil
        self.behavior = .success("mock transcription")
        super.init()
    }

    init(
        providerId: String,
        displayName: String,
        models: [PluginModelInfo],
        selectedModelId: String?,
        behavior: TranscriptionBehavior = .success("mock transcription")
    ) {
        self.providerId = providerId
        self.providerDisplayName = displayName
        self.transcriptionModels = models
        self.selectedModelId = selectedModelId
        self.behavior = behavior
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelOverrides.append(modelId)
        selectedModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try performTranscription(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            usedFileTranscriptionPipeline: false
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let result = try performTranscription(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            usedFileTranscriptionPipeline: true
        )
        _ = onProgress(result.text)
        let processedDuration = result.segments
            .map(\.end)
            .filter(\.isFinite)
            .max() ?? audio.duration
        _ = onSourceProgress(PluginTranscriptionSourceProgress(
            processedDuration: processedDuration,
            totalDuration: audio.duration
        ))
        return result
    }

    private func performTranscription(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        usedFileTranscriptionPipeline: Bool
    ) throws -> PluginTranscriptionResult {
        let request = Request(
            language: language,
            translate: translate,
            prompt: prompt,
            audioSampleCount: audio.samples.count,
            firstAudioSample: audio.samples.first,
            usedFileTranscriptionPipeline: usedFileTranscriptionPipeline
        )
        lastRequest = request
        requests.append(request)
        if case .timed(_, _, let words) = behavior {
            PluginWordTimings.report(words)
        }
        return switch behavior {
        case .success(let text):
            PluginTranscriptionResult(text: text)
        case .empty:
            PluginTranscriptionResult(text: "")
        case .failure(let message):
            throw PluginTranscriptionError.apiError(message)
        case .cancellation:
            throw CancellationError()
        case .timed(let text, let segments, _):
            PluginTranscriptionResult(text: text, segments: segments)
        case .conditionedShortFallbackFailure:
            if prompt?.isEmpty == false {
                PluginTranscriptionResult(
                    text: "incomplete initial transcript",
                    segments: [PluginTranscriptionSegment(text: "incomplete initial transcript", start: 0, end: audio.duration * 0.2)]
                )
            } else {
                throw PluginTranscriptionError.apiError("WhisperKit could not transcribe audio segment 2 of 3")
            }
        case .conditionedShortFallbackComplete(let shortText, let completeText):
            if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PluginTranscriptionResult(
                    text: shortText,
                    segments: [
                        PluginTranscriptionSegment(
                            text: shortText,
                            start: 0,
                            end: audio.duration * 0.2
                        )
                    ]
                )
            } else {
                PluginTranscriptionResult(
                    text: completeText,
                    segments: [
                        PluginTranscriptionSegment(
                            text: completeText,
                            start: 0,
                            end: audio.duration
                        )
                    ]
                )
            }
        }
    }
}

private final class RecorderOverrideMarkerTranscriptionPlugin: NSObject, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.recorder-override-marker"
    static let pluginName = "Recorder Override Marker"

    private let models = [
        PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
        PluginModelInfo(id: "whisper-small", displayName: "Whisper Small")
    ]
    private var selectedModelReadCount = 0
    private var currentModelId = "whisper-large-v3"
    private(set) var selectedModelOverrides: [String] = []

    var providerId: String { "recorder-override-marker" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { true }
    var selectedModelId: String? {
        selectedModelReadCount += 1
        if selectedModelReadCount == 1 {
            currentModelId = "whisper-small"
            return "whisper-large-v3"
        }
        return currentModelId
    }
    var availableModels: [PluginModelInfo] { models }
    var transcriptionModels: [PluginModelInfo] { models }
    var supportsTranslation: Bool { true }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelOverrides.append(modelId)
        currentModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        let mode = selectedModelOverrides.isEmpty ? "unforced" : "forced"
        return PluginTranscriptionResult(text: "\(mode) \(currentModelId)")
    }
}

private struct FixedSpeechRegionDetector: SpeechRegionDetecting {
    let regions: [ClosedRange<TimeInterval>]

    func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>] {
        regions
    }
}

private struct FailingSpeechRegionDetector: SpeechRegionDetecting {
    func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>] {
        throw SpeechDetectionError.unsupportedFormat
    }
}

/// Holds each Recorder transcription until the test finishes it, so a test decides
/// when and how each queued transcript ends.
private actor RecorderTranscriptionGate {
    enum Outcome: Sendable {
        case text(String)
        case failure(String)
    }

    private var waiting: [CheckedContinuation<Outcome, Never>] = []
    /// The first audio sample of each transcription, in the order they started.
    private(set) var startedMarkers: [Float] = []

    var waitingCount: Int { waiting.count }

    func transcribe(marker: Float) async -> Outcome {
        startedMarkers.append(marker)
        return await withCheckedContinuation { waiting.append($0) }
    }

    func finishNext(_ outcome: Outcome) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: outcome)
    }

    func finishAll(_ outcome: Outcome) {
        let all = waiting
        waiting.removeAll()
        all.forEach { $0.resume(returning: outcome) }
    }
}

private final class RecorderGatedTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.recorder-gated"
    static let pluginName = "Recorder Gated Mock"

    let providerId: String
    var providerDisplayName: String { providerId }
    let transcriptionModels = [PluginModelInfo(id: "gated-model", displayName: "Gated Model")]
    var selectedModelId: String? = "gated-model"
    var isConfigured: Bool { true }
    var supportsTranslation: Bool { true }
    private let gate: RecorderTranscriptionGate?

    required override init() {
        providerId = "gated"
        gate = nil
        super.init()
    }

    init(providerId: String, gate: RecorderTranscriptionGate) {
        self.providerId = providerId
        self.gate = gate
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let gate else { return PluginTranscriptionResult(text: "") }
        switch await gate.transcribe(marker: audio.samples.first ?? 0) {
        case .text(let text):
            return PluginTranscriptionResult(text: text)
        case .failure(let message):
            throw PluginTranscriptionError.apiError(message)
        }
    }
}

/// VoiceOver announcements, far enough apart that none counts as a repeat.
@MainActor
private final class RecorderAnnouncementLog {
    let service = AccessibilityAnnouncementService()
    private(set) var messages: [String] = []
    private var clock = ContinuousClock.now

    init() {
        service.isVoiceOverEnabled = { true }
        service.now = { [unowned self] in
            self.clock = self.clock.advanced(by: .seconds(5))
            return self.clock
        }
        service.post = { [unowned self] message, _ in
            self.messages.append(message)
        }
    }
}
