import AVFoundation
import Combine
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SpeakerTranscriptBuilderMacTests: XCTestCase {
    func testTimedTextKeepsSegmentTimesAndSkipsEmptyOrInvalidSegments() {
        let entries = SpeakerTranscriptBuilder.timedText(from: [
            TranscriptionSegment(text: " Hello there. ", start: 0, end: 1.5),
            TranscriptionSegment(text: "  ", start: 1.5, end: 2),
            TranscriptionSegment(text: "Broken", start: 3, end: 2),
            TranscriptionSegment(text: "Hi.", start: 2, end: 2.5),
        ])

        XCTAssertEqual(entries.map(\.text), ["Hello there.", "Hi."])
        XCTAssertEqual(entries.map(\.start), [0, 2])
        XCTAssertEqual(entries.map(\.end), [1.5, 2.5])
    }

    func testProviderLabelsBecomeNumberedSpeakersAndLeaveTheText() throws {
        let transcript = try XCTUnwrap(SpeakerTranscriptBuilder.providerTranscript(
            from: [
                TranscriptionSegment(text: "Speaker B: Good morning.", start: 0, end: 1, speakerLabel: "Speaker B", speakerConfidence: 0.9),
                TranscriptionSegment(text: "Morning.", start: 1, end: 2, speakerLabel: "Speaker A"),
                TranscriptionSegment(text: "Let's start.", start: 2, end: 3, speakerLabel: "Speaker B", speakerConfidence: 1.4),
            ],
            engine: "assemblyai"
        ))

        XCTAssertEqual(transcript.source.kind, .provider)
        XCTAssertEqual(transcript.source.engine, "assemblyai")
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(transcript.segments.map(\.text), ["Good morning.", "Morning.", "Let's start."])
        XCTAssertEqual(transcript.segments.map(\.speakerConfidence), [0.9, nil, 1])
        XCTAssertTrue(transcript.isValid)
    }

    func testStoredLanguageNamesAndLocalesBecomeLanguageCodes() {
        XCTAssertEqual(SpeakerTranscriptBuilder.languageCode(from: "de"), "de")
        XCTAssertEqual(SpeakerTranscriptBuilder.languageCode(from: "de-DE"), "de")
        XCTAssertEqual(SpeakerTranscriptBuilder.languageCode(from: "German"), "de")
        XCTAssertEqual(SpeakerTranscriptBuilder.languageCode(from: "english"), "en")
        XCTAssertNil(SpeakerTranscriptBuilder.languageCode(from: "not a language"))
        XCTAssertNil(SpeakerTranscriptBuilder.languageCode(from: nil))
    }

    func testSegmentsWithoutLabelsGiveNoProviderTranscript() {
        XCTAssertNil(SpeakerTranscriptBuilder.providerTranscript(
            from: [TranscriptionSegment(text: "Hello", start: 0, end: 1)],
            engine: "parakeet"
        ))
    }

    func testAudioIsWrittenAsReadableAAC() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let url = directory.appendingPathComponent("speaker.m4a")
        let samples = (0..<32_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }

        try SpeakerAudioWriter.writeAAC(samples: samples, to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2, accuracy: 0.2)
    }
}

@MainActor
final class SpeakerTranscriptCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!
    private var provider: FakeDiarizationProvider!

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        history = HistoryService(appSupportDirectory: directory)
        provider = FakeDiarizationProvider()
    }

    override func tearDown() async throws {
        history = nil
        TestSupport.remove(directory)
    }

    private func makeCoordinator(provider: FakeDiarizationProvider? = nil) -> SpeakerTranscriptCoordinator {
        let provider = provider ?? self.provider
        return SpeakerTranscriptCoordinator(
            historyService: history,
            providerSource: { provider }
        )
    }

    private func input(labels: Bool = false) -> SpeakerRecordingInput {
        SpeakerRecordingInput(
            result: TranscriptionResult(
                text: "Good morning. Morning. Let's start.",
                detectedLanguage: "en",
                duration: 3,
                processingTime: 0.1,
                engineUsed: "test",
                segments: [
                    TranscriptionSegment(text: "Good morning.", start: 0, end: 1, speakerLabel: labels ? "A" : nil),
                    TranscriptionSegment(text: "Morning.", start: 1, end: 2, speakerLabel: labels ? "B" : nil),
                    TranscriptionSegment(text: "Let's start.", start: 2, end: 3, speakerLabel: labels ? "A" : nil),
                ]
            ),
            samples: [Float](repeating: 0.1, count: 48_000),
            title: "Meeting",
            source: .recorder,
            modelUsed: nil
        )
    }

    private func waitUntilIdle(_ coordinator: SpeakerTranscriptCoordinator) async throws {
        for _ in 0..<400 where !coordinator.stages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.stages.isEmpty)
    }

    func testRecordingIsSavedWithAudioAndGetsSpeakersFromTheProvider() async throws {
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1),
            PluginSpeakerTurn(speakerLabel: "y", start: 1, end: 2),
            PluginSpeakerTurn(speakerLabel: "x", start: 2, end: 3),
        ]
        let coordinator = makeCoordinator()

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.source, .recorder)
        XCTAssertEqual(record.appName, "Meeting")
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertEqual(history.audioFileURL(for: record)?.pathExtension, "m4a")
        XCTAssertFalse(record.historySyncAudioEligible)
        let transcript = try XCTUnwrap(record.speakerTranscript)
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(transcript.source, .init(kind: .local, engine: "fake-diarizer"))
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertNil(provider.requests.first?.speakerCount)
    }

    func testWithSpeakersMailboxListsOnlyRecordsWithSpeakerDetection() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        XCTAssertTrue(history.addRecord(
            rawText: "A dictation",
            finalText: "A dictation",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        ))

        var query = HistoryQuery()
        query.collection = .withSpeakers

        XCTAssertEqual(history.allRecords(query: query).map(\.id), [id])
        XCTAssertEqual(history.recordCount(query: query), 1)
        XCTAssertEqual(history.facets(currentDeviceID: nil).speakerCount, 1)
        XCTAssertEqual(history.totalRecords, 2)
    }

    func testRecordingIsSavedWithoutAnAccount() async throws {
        let coordinator = makeCoordinator()

        let addedID = await coordinator.addRecording(input())

        XCTAssertNotNil(addedID)
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.totalRecords, 1)
        XCTAssertEqual(provider.requests.count, 1)
    }

    /// Issue #1558: the Recorder hands every transcription of a recording to the
    /// intake, so a recording that has its speaker record keeps that one.
    func testARecorderRecordingKeepsItsSpeakerRecordWhenTranscribedAgain() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        var recording = input()
        recording.recorderRecordingID = UUID()

        let firstID = await coordinator.addRecording(recording)
        let id = try XCTUnwrap(firstID)
        try await waitUntilIdle(coordinator)
        let againID = await coordinator.addRecording(recording)

        XCTAssertEqual(againID, id)
        XCTAssertEqual(history.speakerRecords(limit: 10).map(\.id), [id])
        XCTAssertEqual(provider.requests.count, 1)

        // Another recording gets its own record.
        var other = input()
        other.recorderRecordingID = UUID()
        let otherID = await coordinator.addRecording(other)
        XCTAssertNotNil(otherID)
        XCTAssertNotEqual(otherID, id)
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.speakerRecords(limit: 10).count, 2)
    }

    func testEngineLabelsAreUsedWithoutRunningTheProvider() async throws {
        let coordinator = makeCoordinator()

        let addedID = await coordinator.addRecording(input(labels: true))
        let id = try XCTUnwrap(addedID)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertEqual(record.speakerTranscript?.source.kind, .provider)
        XCTAssertEqual(record.speakerTranscript?.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testFailedDetectionMarksTheRecordFailedAndCanBeRetried() async throws {
        provider.error = PluginDiarizationError.processingFailed("boom")
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscriptState, .failed)

        provider.error = nil
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        XCTAssertNil(coordinator.start(recordID: id, speakerCount: 2))
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertEqual(record.speakerTranscript?.requestedSpeakerCount, 2)
        XCTAssertEqual(provider.requests.last?.speakerCount, 2)
    }

    func testRerunWithoutAnAccountReplacesTheTranscript() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        let revision = try XCTUnwrap(history.record(withID: id)?.speakerTranscript?.revision)

        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertNotEqual(record.speakerTranscript?.revision, revision)
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testMissingModelsAreDownloadedBeforeDetection() async throws {
        provider.modelsInstalled = false
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(provider.prepareCalls, 1)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscriptState, .ready)
    }

    func testNamesBelongToOneDetectionRunAndAreFoundBySearch() async throws {
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1),
            PluginSpeakerTurn(speakerLabel: "y", start: 1, end: 3),
        ]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        history.setSpeakerName("  Anna ", for: "S1", inRecordID: id)
        XCTAssertEqual(history.record(withID: id)?.speakerNames?.displayName(for: "S1"), "Anna")
        XCTAssertEqual(history.speakerNameHistory(), ["Anna"])
        XCTAssertEqual(history.searchRecords(query: "anna").map(\.id), [id])

        // Detecting again keeps the name with the voice that is found again.
        let firstRevision = history.record(withID: id)?.speakerTranscript?.revision
        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)
        XCTAssertNotEqual(history.record(withID: id)?.speakerTranscript?.revision, firstRevision)
        XCTAssertEqual(history.record(withID: id)?.speakerNames?.displayName(for: "S1"), "Anna")

        // A run that finds one voice for everything drops the name: most of
        // that speaker's time was not Anna's.
        provider.turns = [PluginSpeakerTurn(speakerLabel: "z", start: 0, end: 3)]
        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscript?.speakerIDs, ["S1"])
        XCTAssertNil(history.record(withID: id)?.speakerNames)
        XCTAssertTrue(history.searchRecords(query: "anna").isEmpty)
    }

    func testCancellingARecordingThatWaitsTakesItOffTheQueueRightAway() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        provider.delay = .milliseconds(500)
        let coordinator = makeCoordinator()
        let firstID = await coordinator.addRecording(input())
        let secondID = await coordinator.addRecording(input())
        let first = try XCTUnwrap(firstID)
        let second = try XCTUnwrap(secondID)
        XCTAssertEqual(coordinator.stages[second], .waiting)

        coordinator.cancel(recordID: second)

        XCTAssertNil(coordinator.stages[second])
        XCTAssertEqual(coordinator.outcomes[second], .cancelled)
        XCTAssertEqual(history.record(withID: second)?.speakerTranscriptState, .failed)
        XCTAssertNotNil(coordinator.stages[first])
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.record(withID: first)?.speakerTranscriptState, .ready)
        XCTAssertEqual(coordinator.outcomes[first], .succeeded)
        XCTAssertEqual(provider.requests.count, 1)
    }

    /// A failed "Detect again" keeps the earlier transcript; the outcome still reports
    /// the failure, so VoiceOver does not hear "Speakers detected".
    func testFailedRerunReportsFailureWhileKeepingTheEarlierTranscript() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(coordinator.outcomes[id], .succeeded)
        let revision = try XCTUnwrap(history.record(withID: id)?.speakerTranscript?.revision)

        provider.error = PluginDiarizationError.processingFailed("boom")
        XCTAssertNil(coordinator.start(recordID: id))
        XCTAssertNil(coordinator.outcomes[id], "A queued run has no outcome yet")
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(coordinator.outcomes[id], .failed)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscriptState, .ready)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscript?.revision, revision)
        XCTAssertEqual(
            HistoryRecordDetailView.speakerDetectionAnnouncement(for: .failed),
            String(localized: "speakers.status.failed")
        )
    }

    func testSpeakerRecordCapturedBeforeClearHistoryIsNotAdded() throws {
        let id = UUID()
        let audioURL = history.speakerAudioFileURL(forRecordID: id)
        try SpeakerAudioWriter.writeAAC(samples: [Float](repeating: 0, count: 16_000), to: audioURL)
        let generation = history.clearGeneration
        history.clearAll()

        XCTAssertFalse(history.addSpeakerRecord(
            id: id,
            text: "Hello",
            title: nil,
            source: .importedFile,
            durationSeconds: 1,
            language: nil,
            engineUsed: "test",
            timedText: [TimedTextEntry(text: "Hello", start: 0, end: 1, utf16Location: 0, utf16Length: 5)],
            granularity: .segment,
            capturedInClearGeneration: generation
        ))
        XCTAssertNil(history.record(withID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDetectionInterruptedByAQuitBecomesFailed() async throws {
        let id = UUID()
        try SpeakerAudioWriter.writeAAC(
            samples: [Float](repeating: 0, count: 16_000),
            to: history.speakerAudioFileURL(forRecordID: id)
        )
        XCTAssertTrue(history.addSpeakerRecord(
            id: id,
            text: "Hello",
            title: nil,
            source: .importedFile,
            durationSeconds: 1,
            language: nil,
            engineUsed: "test",
            timedText: [TimedTextEntry(text: "Hello", start: 0, end: 1, utf16Location: 0, utf16Length: 5)],
            granularity: .segment
        ))
        XCTAssertEqual(history.record(withID: id)?.speakerTranscriptState, .pending)

        history.failInterruptedSpeakerTranscripts()

        XCTAssertEqual(history.record(withID: id)?.speakerTranscriptState, .failed)
    }

    func testRecordWithoutTimingIsTranscribedAgainBeforeDetection() async throws {
        let id = UUID()
        let audioFileName = history.writeAudioFile([Float](repeating: 0.1, count: 16_000), forRecordID: id)
        XCTAssertTrue(history.addRecord(
            id: id,
            rawText: "Hello there",
            finalText: "Hello there",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test",
            audioFileName: audioFileName
        ))
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1)]
        let coordinator = makeCoordinator()
        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(coordinator.startError(for: record), .timingMissing)

        var requestedLanguage: String?
        coordinator.timingSource = { _, language in
            requestedLanguage = language
            return TranscriptionResult(
                text: "Hello there",
                detectedLanguage: language,
                duration: 1,
                processingTime: 0.1,
                engineUsed: "test",
                segments: [TranscriptionSegment(text: "Hello there", start: 0, end: 1)]
            )
        }
        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)

        XCTAssertEqual(requestedLanguage, "en")
        XCTAssertEqual(record.timedTextGranularity, .segment)
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertEqual(record.speakerTranscript?.segments.map(\.speakerID), ["S1"])
        XCTAssertEqual(record.finalText, "Hello there")
    }

    /// The Speakers page shows a waiting record at the step it runs next.
    func testAWaitingRecordStartsWithTranscriptionOnlyWhenItLacksTiming() throws {
        let coordinator = makeCoordinator()

        let untimedID = UUID()
        XCTAssertTrue(history.addRecord(
            id: untimedID,
            rawText: "Hello there",
            finalText: "Hello there",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 1,
            language: "en",
            engineUsed: "test"
        ))
        let untimed = try XCTUnwrap(history.record(withID: untimedID))
        XCTAssertFalse(coordinator.runStartsWithTranscription(for: untimed), "Without a timing pass it cannot start")

        let segment = TimedTextEntry(text: "Hello", start: 0, end: 1, utf16Location: 0, utf16Length: 5)
        func addTimedRecord(words: [TranscriptionWord]) throws -> TranscriptionRecord {
            let id = UUID()
            XCTAssertTrue(history.addSpeakerRecord(
                id: id,
                text: "Hello",
                title: nil,
                source: .importedFile,
                durationSeconds: 1,
                language: "en",
                engineUsed: "test",
                timedText: [segment],
                granularity: .segment,
                words: words
            ))
            return try XCTUnwrap(history.record(withID: id))
        }
        let segmentsOnly = try addTimedRecord(words: [])
        let withWords = try addTimedRecord(words: [TranscriptionWord(text: "Hello", start: 0, end: 1)])

        XCTAssertFalse(coordinator.runStartsWithTranscription(for: segmentsOnly))
        XCTAssertFalse(coordinator.runStartsWithTranscription(for: withWords))

        coordinator.timingSource = { _, _ in
            TranscriptionResult(text: "", detectedLanguage: nil, duration: 1, processingTime: 0, engineUsed: "test", segments: [])
        }
        XCTAssertTrue(coordinator.runStartsWithTranscription(for: untimed))
        XCTAssertFalse(coordinator.runStartsWithTranscription(for: segmentsOnly), "Segment timing needs no first pass")

        coordinator.wordTimingSource = { _, _ in [] }
        XCTAssertTrue(coordinator.runStartsWithTranscription(for: segmentsOnly), "The second pass adds word timing first")
        XCTAssertFalse(coordinator.runStartsWithTranscription(for: withWords), "Word timing goes straight to detection")
    }

    func testRecordingWithoutTimestampsIsKeptAndTranscribedAgainForDetection() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        let timed = input()
        let untimed = SpeakerRecordingInput(
            result: TranscriptionResult(
                text: timed.result.text,
                detectedLanguage: "en",
                duration: 3,
                processingTime: 0.1,
                engineUsed: "test",
                segments: []
            ),
            samples: timed.samples,
            title: timed.title,
            source: timed.source,
            modelUsed: nil
        )
        let withoutTimingSource = await coordinator.addRecording(untimed)
        XCTAssertNil(withoutTimingSource)

        coordinator.timingSource = { _, language in
            TranscriptionResult(
                text: "Good morning. Morning. Let's start.",
                detectedLanguage: language,
                duration: 3,
                processingTime: 0.1,
                engineUsed: "test",
                segments: [TranscriptionSegment(text: "Good morning. Morning. Let's start.", start: 0, end: 3)]
            )
        }
        let addedID = await coordinator.addRecording(untimed)
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.timedTextGranularity, .segment)
        XCTAssertEqual(record.speakerTranscriptState, .ready)
    }

    func testTimingPassKeepsTheSavedTextWhenItHearsDifferentWords() async throws {
        let id = UUID()
        let audioFileName = history.writeAudioFile([Float](repeating: 0.1, count: 64_000), forRecordID: id)
        XCTAssertTrue(history.addRecord(
            id: id,
            rawText: "Hello there. How are you today?",
            finalText: "Hello there. How are you today?",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 4,
            language: "en",
            engineUsed: "test",
            audioFileName: audioFileName
        ))
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1.5),
            PluginSpeakerTurn(speakerLabel: "y", start: 1.5, end: 4),
        ]
        let coordinator = makeCoordinator()
        coordinator.timingSource = { _, language in
            TranscriptionResult(
                text: "hello their how are you to day",
                detectedLanguage: language,
                duration: 4,
                processingTime: 0.1,
                engineUsed: "test",
                segments: [
                    TranscriptionSegment(text: "hello their", start: 0, end: 1.4),
                    TranscriptionSegment(text: "how are you to day", start: 1.6, end: 4),
                ]
            )
        }

        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.timedText.map(\.text), ["Hello there.", "How are you today?"])
        XCTAssertEqual(record.timedText.first?.start, 0)
        XCTAssertEqual(record.timedText.last?.start ?? 0, 1.6, accuracy: 0.01)
        let transcript = try XCTUnwrap(record.speakerTranscript)
        XCTAssertEqual(transcript.segments.map(\.text), ["Hello there.", "How are you today?"])
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(record.finalText, "Hello there. How are you today?")
    }

    /// Issue #1558: text without spaces between words, such as Japanese, kept
    /// the timing pass's wording instead of the saved text.
    func testTimingPassKeepsTheSavedTextWithoutSpacesBetweenWords() async throws {
        let id = UUID()
        let text = "おはようございます。今日は会議を始めましょう。"
        let audioFileName = history.writeAudioFile([Float](repeating: 0.1, count: 64_000), forRecordID: id)
        XCTAssertTrue(history.addRecord(
            id: id,
            rawText: text,
            finalText: text,
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 4,
            language: "ja",
            engineUsed: "test",
            audioFileName: audioFileName
        ))
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1.4),
            PluginSpeakerTurn(speakerLabel: "y", start: 1.4, end: 4),
        ]
        let coordinator = makeCoordinator()
        coordinator.timingSource = { _, language in
            TranscriptionResult(
                text: "おはようございます。今日は会議を始めよう。",
                detectedLanguage: language,
                duration: 4,
                processingTime: 0.1,
                engineUsed: "test",
                segments: [
                    TranscriptionSegment(text: "おはようございます。", start: 0, end: 1.2),
                    TranscriptionSegment(text: "今日は会議を始めよう。", start: 1.6, end: 3.8),
                ],
                words: [
                    TranscriptionWord(text: "おはよう", start: 0, end: 0.6),
                    TranscriptionWord(text: "ございます", start: 0.6, end: 1.2),
                    TranscriptionWord(text: "今日", start: 1.6, end: 2.0),
                    TranscriptionWord(text: "は", start: 2.0, end: 2.1),
                    TranscriptionWord(text: "会議", start: 2.1, end: 2.6),
                    TranscriptionWord(text: "を", start: 2.6, end: 2.7),
                    TranscriptionWord(text: "始めよう", start: 2.7, end: 3.8),
                ]
            )
        }

        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.timedText.map(\.text), ["おはようございます。", "今日は会議を始めましょう。"])
        XCTAssertEqual(record.timedText.map(\.start), [0, 1.6])
        XCTAssertEqual(record.speakerWordsAreFromSecondPass, true)
        let transcript = try XCTUnwrap(record.speakerTranscript)
        XCTAssertEqual(transcript.segments.map(\.text), ["おはようございます。", "今日は会議を始めましょう。"])
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(record.finalText, text)
    }

    /// Issue #1558: detecting speakers again after a paragraph edit rebuilt the
    /// transcript from the transcription and lost the edit, while `finalText`
    /// kept it.
    func testDetectingSpeakersAgainKeepsAParagraphEdit() async throws {
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1),
            PluginSpeakerTurn(speakerLabel: "y", start: 1, end: 2),
            PluginSpeakerTurn(speakerLabel: "x", start: 2, end: 3),
        ]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        let first = try XCTUnwrap(history.record(withID: id)?.speakerTranscript)
        XCTAssertTrue(history.updateSpeakerTranscript(
            first.replacingText(ofSegmentsIn: 1..<2, with: "Good morning to you."),
            names: nil,
            forRecordID: id,
            updatesText: true
        ))
        let editedText = "Good morning. Good morning to you. Let's start."
        XCTAssertEqual(history.record(withID: id)?.finalText, editedText)

        // The second run hears the first two sentences from one speaker.
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 2),
            PluginSpeakerTurn(speakerLabel: "y", start: 2, end: 3),
        ]
        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        let second = try XCTUnwrap(record.speakerTranscript)
        XCTAssertNotEqual(second.revision, first.revision)
        XCTAssertEqual(second.segments.map(\.text), ["Good morning.", "Good morning to you.", "Let's start."])
        XCTAssertEqual(second.segments.map(\.speakerID), ["S1", "S1", "S2"])
        XCTAssertEqual(second.joinedText, record.finalText)
        XCTAssertEqual(record.finalText, editedText)
        XCTAssertEqual(record.rawText, "Good morning. Morning. Let's start.")
        XCTAssertEqual(record.timedText.map(\.text), ["Good morning.", "Morning.", "Let's start."])
    }

    func testRecordingWithoutWordTimingGetsItFromTheSecondPass() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        var requestedLanguage: String?
        coordinator.wordTimingSource = { _, language in
            requestedLanguage = language
            return [
                TranscriptionWord(text: "Good", start: 0.1, end: 0.3),
                TranscriptionWord(text: "morning", start: 0.4, end: 0.9),
            ]
        }

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(requestedLanguage, "en")
        XCTAssertEqual(record.speakerWords.map(\.text), ["Good", "morning"])
        XCTAssertEqual(record.speakerWordsAreFromSecondPass, true)
        XCTAssertEqual(record.speakerTranscriptState, .ready)
    }

    func testAFailingSecondPassLeavesSegmentTimingAndStillDetectsSpeakers() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        coordinator.wordTimingSource = { _, _ in throw TranscriptionEngineError.noEngineSelected }

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertTrue(record.speakerWords.isEmpty)
        XCTAssertEqual(record.speakerTranscriptState, .ready)
    }

    func testVoicesAreStoredUnderTheNumberedSpeakersOfTheTranscript() async throws {
        // The provider hears "y" second, so it becomes S2.
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1),
            PluginSpeakerTurn(speakerLabel: "y", start: 1, end: 3),
        ]
        provider.embeddings = ["y": [0, 1], "x": [1, 0], "unused": [1, 1]]
        let coordinator = makeCoordinator()
        let store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles"))
        coordinator.voices = SpeakerVoiceProfileService(
            store: store,
            historyService: history
        )

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let revision = try XCTUnwrap(history.record(withID: id)?.speakerTranscript?.revision)
        XCTAssertEqual(store.embeddings(forRecordID: id, revision: revision), ["S1": [1, 0], "S2": [0, 1]])
        XCTAssertEqual(store.embeddingModel(forRecordID: id, revision: revision), "fake-diarizer")
    }

    func testOwnSpeechFromTheMicrophoneBecomesTheSpeakerMe() async throws {
        // The diarizer hears one voice for everything; the microphone says the middle is the user.
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        provider.embeddings = ["x": [1, 0]]
        let coordinator = makeCoordinator()
        let store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles"))
        coordinator.voices = SpeakerVoiceProfileService(store: store, historyService: history)
        var recording = input()
        recording.ownSpeech = [1...2]

        let addedID = await coordinator.addRecording(recording)
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let record = try XCTUnwrap(history.record(withID: id))
        let transcript = try XCTUnwrap(record.speakerTranscript)
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(transcript.source.engine, "fake-diarizer+microphone-channel")
        XCTAssertEqual(record.speakerNames?.displayName(for: "S2"), String(localized: "speakers.me"))
        XCTAssertNil(record.speakerNames?.displayName(for: "S1"))
        XCTAssertEqual(store.embeddings(forRecordID: id, revision: transcript.revision), ["S1": [1, 0]])

        // Detecting again uses the stored microphone activity and keeps a new name.
        history.setSpeakerName("Marco", for: "S2", inRecordID: id)
        XCTAssertNil(coordinator.start(recordID: id))
        try await waitUntilIdle(coordinator)
        XCTAssertEqual(history.record(withID: id)?.speakerTranscript?.segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(history.record(withID: id)?.speakerNames?.displayName(for: "S2"), "Marco")
    }

    func testLabellingForAPIAndWatchFolderWritesSpeakerNumbersWithoutAHistoryRecord() async throws {
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 1),
            PluginSpeakerTurn(speakerLabel: "y", start: 1, end: 3),
        ]
        let coordinator = makeCoordinator()
        let recording = input()

        let segments = try await coordinator.labelingSpeakers(
            in: recording.result,
            samples: recording.samples,
            speakerCount: 2
        )

        XCTAssertEqual(segments.map(\.speakerLabel), ["Speaker 1", "Speaker 2", "Speaker 2"])
        XCTAssertEqual(segments.map(\.text), ["Good morning.", "Morning.", "Let's start."])
        XCTAssertEqual(provider.requests.last?.speakerCount, 2)
        XCTAssertEqual(history.totalRecords, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(provider.requests.last).audioURL.path))
        XCTAssertEqual(
            WatchFolderService.result(recording.result, labelledWith: segments).text,
            "Speaker 1: Good morning.\n\nSpeaker 2: Morning. Let's start."
        )
    }

    func testLabellingKeepsLabelsAnEngineReturned() async throws {
        let coordinator = makeCoordinator()
        let labelled = input(labels: true)

        let kept = try await coordinator.labelingSpeakers(in: labelled.result, samples: labelled.samples)
        XCTAssertEqual(kept.map(\.speakerLabel), ["A", "B", "A"])
        XCTAssertTrue(provider.requests.isEmpty)

    }

    func testAFixedSpeakerCountDetectsAgainOverEngineLabels() async throws {
        provider.turns = [
            PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 2),
            PluginSpeakerTurn(speakerLabel: "y", start: 2, end: 3),
        ]
        let coordinator = makeCoordinator()
        let labelled = input(labels: true)

        let detected = try await coordinator.labelingSpeakers(in: labelled.result, samples: labelled.samples, speakerCount: 2)

        XCTAssertEqual(provider.requests.map(\.speakerCount), [2])
        XCTAssertEqual(Set(detected.compactMap(\.speakerLabel)), ["Speaker 1", "Speaker 2"])
    }

    func testEngineLabelsInTheTextAreNotWrittenTwice() {
        let text = SpeakerTranscriptBuilder.textWithSpeakers([
            TranscriptionSegment(text: "Speaker B: Good morning.", start: 0, end: 1, speakerLabel: "Speaker B"),
            TranscriptionSegment(text: "Hello.", start: 1, end: 2, speakerLabel: "Speaker A"),
        ])
        XCTAssertEqual(text, "Speaker B: Good morning.\n\nSpeaker A: Hello.")
    }

    func testPromotionWaitsForQueuedAndRunningSpeakerDetection() async throws {
        for waitForProvider in [false, true] {
            let coordinator = makeCoordinator()
            let addedID = await coordinator.addRecording(input(labels: true))
            let id = try XCTUnwrap(addedID)
            let record = try XCTUnwrap(history.record(withID: id))
            let version = HistoryTranscriptionVersion(rawText: "New transcript.", finalText: "New transcript.", engineID: "new-engine")
            try history.appendTranscriptionVersion(version, to: record, expected: .capture(record))
            let original = HistoryTranscriptionVersion.capture(record)
            var release: CheckedContinuation<Void, Never>?
            provider.beforeDiarization = {
                await withCheckedContinuation { release = $0 }
            }
            defer { release?.resume() }
            XCTAssertNil(coordinator.start(recordID: id))
            if waitForProvider {
                for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertNotNil(release)
            }
            XCTAssertThrowsError(try history.promoteTranscriptionVersion(version.id, in: record)) {
                XCTAssertEqual($0.localizedDescription, HistoryRetranscriptionError.busy.localizedDescription)
            }
            XCTAssertEqual(HistoryTranscriptionVersion.capture(record), original)
            XCTAssertNil(record.activeTranscriptionVersionID)
            for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
            let continuation = try XCTUnwrap(release)
            release = nil
            continuation.resume()
            try await waitUntilIdle(coordinator)
            try history.promoteTranscriptionVersion(version.id, in: record)
            XCTAssertEqual(record.rawText, "New transcript.")
            XCTAssertNil(record.speakerTranscript)
            XCTAssertTrue(version.isActive(in: record))
        }
    }

    func testSyncedPromotionInvalidatesEverySuspendedSpeakerDetectionPhase() async throws {
        for phase in ["timing", "words", "models", "diarization", "failure"] {
            provider = FakeDiarizationProvider()
            provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
            let coordinator = makeCoordinator()
            let addedID = await coordinator.addRecording(input(labels: true))
            let id = try XCTUnwrap(addedID)
            let record = try XCTUnwrap(history.record(withID: id))
            var release: CheckedContinuation<Void, Never>?
            let pause: @MainActor () async -> Void = {
                await withCheckedContinuation { release = $0 }
            }
            defer { release?.resume() }
            switch phase {
            case "timing":
                record.timedTextData = nil
                record.timedTextGranularityRaw = nil
                coordinator.timingSource = { _, _ in
                    await pause()
                    return self.input().result
                }
            case "words":
                coordinator.wordTimingSource = { _, _ in
                    await pause()
                    return [TranscriptionWord(text: "Good", start: 0, end: 0.5)]
                }
            case "models":
                provider.modelsInstalled = false
                provider.beforePreparation = pause
            default:
                provider.beforeDiarization = pause
                if phase == "failure" { provider.error = PluginDiarizationError.processingFailed("test") }
            }
            XCTAssertNil(coordinator.start(recordID: id), phase)
            for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
            let continuation = try XCTUnwrap(release, phase)
            let reset = Date(timeIntervalSinceNow: 60)
            // A promotion can invalidate alignment even if its raw text is unchanged.
            let replacement = phase == "models" ? record.rawText : "Synced replacement."
            let content = UserDataSyncHistoryContentV1(
                recordID: id, createdAt: record.timestamp, updatedAt: reset,
                originDeviceID: "another-device", originPlatform: "macOS",
                source: record.source.rawValue, processingState: "ready",
                rawTranscript: replacement, finalText: replacement,
                durationSeconds: record.durationSeconds, engineDisplayName: "remote-engine",
                alignmentResetAt: reset
            )
            try history.applyUserDataSyncMutations([.upsertHistoryContent(content)])
            release = nil
            continuation.resume()
            try await waitUntilIdle(coordinator)
            XCTAssertEqual(record.rawText, replacement, phase)
            XCTAssertNil(record.speakerTranscript, phase)
            XCTAssertNil(record.speakerTranscriptStateRaw, phase)
            XCTAssertNil(record.timedTextData, phase)
            XCTAssertNil(record.speakerWordsData, phase)
            XCTAssertNil(record.speakerNamesData, phase)
            XCTAssertEqual(record.speakerTranscriptUpdatedAt, reset, phase)
            XCTAssertEqual(provider.requests.count, ["diarization", "failure"].contains(phase) ? 1 : 0, phase)
        }
    }

}

private final class FakeDiarizationProvider: SpeakerDiarizationProviderPlugin, @unchecked Sendable {
    static let pluginId = "test.diarizer"
    static let pluginName = "Test Diarizer"

    var turns: [PluginSpeakerTurn] = []
    var embeddings: [String: [Float]] = [:]
    var error: Error?
    var modelsInstalled = true
    /// How long each detection takes.
    var delay: Duration?
    var beforePreparation: (@MainActor () async -> Void)?
    var beforeDiarization: (@MainActor () async -> Void)?
    private(set) var requests: [PluginDiarizationRequest] = []
    private(set) var prepareCalls = 0

    init() {}
    func activate(host: HostServices) {}
    func deactivate() {}

    var diarizationProviderId: String { Self.pluginId }
    var diarizationProviderDisplayName: String { Self.pluginName }
    var areDiarizationModelsInstalled: Bool { modelsInstalled }
    var supportedSpeakerCounts: ClosedRange<Int> { 2...8 }

    func prepareDiarizationModels(onProgress: @Sendable @escaping (Double) -> Void) async throws {
        prepareCalls += 1
        if let beforePreparation { await beforePreparation() }
        modelsInstalled = true
    }

    func deleteDiarizationModels() async throws {
        modelsInstalled = false
    }

    func unloadDiarizationModels() async {}

    func diarize(
        _ request: PluginDiarizationRequest,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        requests.append(request)
        if let beforeDiarization { await beforeDiarization() }
        if let delay { try await Task.sleep(for: delay) }
        if let error { throw error }
        return PluginDiarizationResult(turns: turns, speakerEmbeddings: embeddings, engine: "fake-diarizer")
    }
}

final class SpeakerChannelAttributionTests: XCTestCase {
    private let sampleRate = 16_000.0

    /// A track that is a tone inside the given seconds and near silence elsewhere.
    private func track(duration: TimeInterval, speech: [ClosedRange<TimeInterval>], level: Float, noise: Float = 0.0005) -> [Float] {
        (0..<Int(duration * sampleRate)).map { index in
            let time = Double(index) / sampleRate
            let amplitude = speech.contains { $0.contains(time) } ? level : noise
            return amplitude * Float(sin(Double(index) * 0.3))
        }
    }

    func testOwnSpeechIsWhereTheMicrophoneIsActive() {
        let microphone = track(duration: 10, speech: [1...3, 6...7], level: 0.2)
        let system = track(duration: 10, speech: [3.5...5.5], level: 0.3)

        let ranges = SpeakerChannelAttribution.ownSpeechRanges(microphone: microphone, system: system)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0.9, accuracy: 0.06)
        XCTAssertEqual(ranges[0].upperBound, 3.1, accuracy: 0.06)
        XCTAssertEqual(ranges[1].lowerBound, 5.9, accuracy: 0.06)
        XCTAssertEqual(ranges[1].upperBound, 7.1, accuracy: 0.06)
    }

    func testRemoteVoicesPickedUpFromLoudspeakersAreNotOwnSpeech() {
        // The microphone hears the user loudly at 1–3 s and the remote voice quietly at 5–8 s.
        var microphone = track(duration: 10, speech: [1...3], level: 0.2)
        let bleed = track(duration: 10, speech: [5...8], level: 0.03, noise: 0)
        for index in microphone.indices { microphone[index] += bleed[index] }
        let system = track(duration: 10, speech: [5...8], level: 0.3)

        let ranges = SpeakerChannelAttribution.ownSpeechRanges(microphone: microphone, system: system)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].lowerBound, 0.9, accuracy: 0.06)
        XCTAssertEqual(ranges[0].upperBound, 3.1, accuracy: 0.06)
    }

    func testSilentMicrophoneAndShortBlipsGiveNoOwnSpeech() {
        let system = track(duration: 5, speech: [1...4], level: 0.3)

        XCTAssertTrue(SpeakerChannelAttribution.ownSpeechRanges(
            microphone: track(duration: 5, speech: [], level: 0),
            system: system
        ).isEmpty)
        XCTAssertTrue(SpeakerChannelAttribution.ownSpeechRanges(
            microphone: track(duration: 5, speech: [2...2.1], level: 0.2),
            system: track(duration: 5, speech: [], level: 0)
        ).isEmpty)
        XCTAssertTrue(SpeakerChannelAttribution.ownSpeechRanges(microphone: [], system: system).isEmpty)
    }

    func testOwnSpeechIsCutOutOfDiarizerTurns() {
        let turns = [
            PluginSpeakerTurn(speakerLabel: "a", start: 0, end: 10),
            PluginSpeakerTurn(speakerLabel: "b", start: 10, end: 12),
        ]

        let combined = SpeakerChannelAttribution.combining(turns, ownSpeech: [4...6, 9.9...12])

        XCTAssertEqual(combined, [
            PluginSpeakerTurn(speakerLabel: "a", start: 0, end: 4),
            PluginSpeakerTurn(speakerLabel: SpeakerChannelAttribution.ownSpeakerLabel, start: 4, end: 6),
            PluginSpeakerTurn(speakerLabel: "a", start: 6, end: 9.9),
            PluginSpeakerTurn(speakerLabel: SpeakerChannelAttribution.ownSpeakerLabel, start: 9.9, end: 12),
        ])
        XCTAssertEqual(SpeakerChannelAttribution.combining(turns, ownSpeech: []), turns)
    }
}

/// The Speakers row, and the VoiceOver value read from it, show the step a record runs next.
@MainActor
final class SpeakerRecordingRowPhaseTests: XCTestCase {
    private let transcribe = String(localized: "speakers.page.step.transcribe")
    private let detect = String(localized: "speakers.page.step.detect")

    func testAWaitingRecordShowsTheStepItsRunStartsWith() {
        let waiting = String(localized: "speakers.status.waiting")

        let transcribedFirst = SpeakerRecordingRow.Phase.speakerDetection(.waiting, startsWithTranscription: true)
        XCTAssertEqual(transcribedFirst, .working(step: 1, detail: waiting, fraction: nil))
        let spokenTranscribedFirst = SpeakerRecordingRow.accessibilityStatus(detail: "", phase: transcribedFirst)
        XCTAssertTrue(spokenTranscribedFirst.contains(transcribe), spokenTranscribedFirst)
        XCTAssertFalse(spokenTranscribedFirst.contains(detect), spokenTranscribedFirst)

        let detectedRightAway = SpeakerRecordingRow.Phase.speakerDetection(.waiting, startsWithTranscription: false)
        XCTAssertEqual(detectedRightAway, .working(step: 2, detail: waiting, fraction: nil))
        let spokenDetectedRightAway = SpeakerRecordingRow.accessibilityStatus(detail: "", phase: detectedRightAway)
        XCTAssertTrue(spokenDetectedRightAway.contains(detect), spokenDetectedRightAway)
        XCTAssertFalse(spokenDetectedRightAway.contains(transcribe), spokenDetectedRightAway)
    }

    func testARunningRecordShowsTheStageItIsIn() {
        XCTAssertEqual(
            SpeakerRecordingRow.Phase.speakerDetection(.transcribing, startsWithTranscription: false),
            .working(step: 1, detail: String(localized: "speakers.status.transcribing"), fraction: nil)
        )
        XCTAssertEqual(
            SpeakerRecordingRow.Phase.speakerDetection(.downloadingModels(0.3), startsWithTranscription: true),
            .working(step: 2, detail: String(localized: "speakers.status.downloadingModel"), fraction: nil)
        )
        XCTAssertEqual(
            SpeakerRecordingRow.Phase.speakerDetection(.detecting(0.5), startsWithTranscription: true),
            .working(step: 2, detail: "", fraction: 0.5)
        )
    }
}
