import AVFoundation
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
    private var hasPremium = true

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        history = HistoryService(appSupportDirectory: directory)
        provider = FakeDiarizationProvider()
        hasPremium = true
    }

    override func tearDown() async throws {
        history = nil
        TestSupport.remove(directory)
    }

    private func makeCoordinator(provider: FakeDiarizationProvider? = nil) -> SpeakerTranscriptCoordinator {
        let provider = provider ?? self.provider
        return SpeakerTranscriptCoordinator(
            historyService: history,
            providerSource: { provider },
            premiumAccess: { [unowned self] in self.hasPremium }
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

    func testNothingIsSavedOrDetectedWithoutPremium() async throws {
        hasPremium = false
        let coordinator = makeCoordinator()

        let addedID = await coordinator.addRecording(input())

        XCTAssertNil(addedID)
        XCTAssertEqual(history.totalRecords, 0)
        XCTAssertTrue(provider.requests.isEmpty)
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

    func testRerunWithoutPremiumKeepsTheExistingTranscript() async throws {
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        let coordinator = makeCoordinator()
        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)
        let revision = try XCTUnwrap(history.record(withID: id)?.speakerTranscript?.revision)

        hasPremium = false
        XCTAssertEqual(coordinator.start(recordID: id), .premiumRequired)

        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(record.speakerTranscriptState, .ready)
        XCTAssertEqual(record.speakerTranscript?.revision, revision)
        XCTAssertEqual(provider.requests.count, 1)
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
            historyService: history,
            premiumAccess: { [unowned self] in self.hasPremium }
        )

        let addedID = await coordinator.addRecording(input())
        let id = try XCTUnwrap(addedID)
        try await waitUntilIdle(coordinator)

        let revision = try XCTUnwrap(history.record(withID: id)?.speakerTranscript?.revision)
        XCTAssertEqual(store.embeddings(forRecordID: id, revision: revision), ["S1": [1, 0], "S2": [0, 1]])
    }

    func testOwnSpeechFromTheMicrophoneBecomesTheSpeakerMe() async throws {
        // The diarizer hears one voice for everything; the microphone says the middle is the user.
        provider.turns = [PluginSpeakerTurn(speakerLabel: "x", start: 0, end: 3)]
        provider.embeddings = ["x": [1, 0]]
        let coordinator = makeCoordinator()
        let store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles"))
        coordinator.voices = SpeakerVoiceProfileService(store: store, historyService: history, premiumAccess: { true })
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

    func testLabellingNeedsPremiumAndKeepsLabelsAnEngineReturned() async throws {
        let coordinator = makeCoordinator()
        let labelled = input(labels: true)

        let kept = try await coordinator.labelingSpeakers(in: labelled.result, samples: labelled.samples)
        XCTAssertEqual(kept.map(\.speakerLabel), ["A", "B", "A"])
        XCTAssertTrue(provider.requests.isEmpty)

        hasPremium = false
        do {
            _ = try await coordinator.labelingSpeakers(in: input().result, samples: input().samples)
            XCTFail("Expected the Premium error")
        } catch let error as SpeakerTranscriptCoordinator.StartError {
            XCTAssertEqual(error, .premiumRequired)
        }
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSupporterStatusDoesNotUnlockSpeakerDetection() {
        XCTAssertFalse(SpeakerWorkspacePremiumAccess.isGranted(hasCommercialLicense: false, hasPremiumEntitlement: false))
        XCTAssertTrue(SpeakerWorkspacePremiumAccess.isGranted(hasCommercialLicense: true, hasPremiumEntitlement: false))
        XCTAssertTrue(SpeakerWorkspacePremiumAccess.isGranted(hasCommercialLicense: false, hasPremiumEntitlement: true))
    }
}

private final class FakeDiarizationProvider: SpeakerDiarizationProviderPlugin, @unchecked Sendable {
    static let pluginId = "test.diarizer"
    static let pluginName = "Test Diarizer"

    var turns: [PluginSpeakerTurn] = []
    var embeddings: [String: [Float]] = [:]
    var error: Error?
    var modelsInstalled = true
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
