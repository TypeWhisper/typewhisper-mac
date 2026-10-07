import XCTest
@testable import TypeWhisper

final class SpeakerWorkspaceTests: XCTestCase {
    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ speaker: String?) -> SpeakerTranscriptSegment {
        SpeakerTranscriptSegment(text: text, start: start, end: end, speakerID: speaker)
    }

    private func transcript(_ segments: [SpeakerTranscriptSegment]) -> SpeakerTranscript {
        SpeakerTranscript(source: .localDiarizer, segments: segments)
    }

    // MARK: - Paragraphs

    func testLongTurnBreaksIntoParagraphsAtPauses() throws {
        let transcript = transcript([
            segment("First.", 0, 2, "S1"),
            segment("Second.", 2.2, 4, "S1"),
            segment("After a pause.", 6, 8, "S1"),
            segment("Reply.", 8.2, 9, "S2"),
        ])
        let turns = SpeakerTranscriptPresentation.turns(of: transcript)

        let paragraphs = SpeakerTranscriptPresentation.paragraphs(of: turns[0], in: transcript)

        XCTAssertEqual(paragraphs.map(\.text), ["First. Second.", "After a pause."])
        XCTAssertEqual(paragraphs.map(\.start), [0, 6])
        XCTAssertEqual(paragraphs.map(\.end), [4, 8])
        XCTAssertEqual(paragraphs.map(\.segmentRange), [0..<2, 2..<3])
        XCTAssertEqual(SpeakerTranscriptPresentation.paragraphs(of: turns[1], in: transcript).map(\.segmentRange), [3..<4])
    }

    func testVeryLongStretchWithoutPauseStillBreaks() {
        let sentence = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) + "."
        let transcript = transcript((0..<6).map { segment(sentence, Double($0), Double($0) + 1, "S1") })
        let turn = SpeakerTranscriptPresentation.turns(of: transcript)[0]

        let paragraphs = SpeakerTranscriptPresentation.paragraphs(of: turn, in: transcript)

        // Each sentence has 150 characters; three reach the paragraph length.
        XCTAssertEqual(paragraphs.map(\.segmentRange), [0..<3, 3..<6])
    }

    func testSpokenTurnEndsWithTheTurnNotWithTheNextOne() {
        let turns = SpeakerTranscriptPresentation.turns(of: transcript([
            segment("A", 0, 2, "S1"),
            segment("B", 10, 12, "S2"),
        ]))

        XCTAssertEqual(SpeakerTranscriptPresentation.spokenTurn(in: turns, at: 1)?.speakerID, "S1")
        XCTAssertNil(SpeakerTranscriptPresentation.spokenTurn(in: turns, at: 5))
        XCTAssertEqual(SpeakerTranscriptPresentation.spokenTurn(in: turns, at: 10)?.speakerID, "S2")
    }

    // MARK: - Playback plan

    private var planTurns: [SpeakerTranscriptTurn] {
        SpeakerTranscriptPresentation.turns(of: transcript([
            segment("A", 1, 4, "S1"),
            segment("B", 4.5, 8, "S2"),
            segment("C", 20, 24, "S1"),
        ]))
    }

    func testWholeRecordingPlaysWithoutFilterOrSilenceSkipping() {
        XCTAssertEqual(
            SpeakerPlaybackPlan.ranges(turns: planTurns, audibleSpeakers: nil, skipsSilence: false, duration: 30),
            [0...30]
        )
    }

    func testSkippingSilenceJoinsCloseTurnsAndDropsLongGaps() {
        let ranges = SpeakerPlaybackPlan.ranges(turns: planTurns, audibleSpeakers: nil, skipsSilence: true, duration: 30)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 0.8, accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 8.2, accuracy: 0.001)
        XCTAssertEqual(ranges[1].lowerBound, 19.8, accuracy: 0.001)
        XCTAssertEqual(ranges[1].upperBound, 24.2, accuracy: 0.001)
    }

    func testSoloPlaysOnlyThatSpeakersTurns() {
        let ranges = SpeakerPlaybackPlan.ranges(turns: planTurns, audibleSpeakers: ["S1"], skipsSilence: false, duration: 30)

        XCTAssertEqual(ranges.map { ($0.lowerBound * 10).rounded() / 10 }, [0.8, 19.8])
        XCTAssertEqual(ranges.map { ($0.upperBound * 10).rounded() / 10 }, [4.2, 24.2])
        XCTAssertTrue(SpeakerPlaybackPlan.ranges(turns: planTurns, audibleSpeakers: [], skipsSilence: false, duration: 30).isEmpty)
    }

    func testPositionJumpsToTheNextPlayedStretchAndEndsAfterTheLast() {
        let ranges: [ClosedRange<TimeInterval>] = [1...4, 20...24]

        XCTAssertEqual(SpeakerPlaybackPlan.position(from: 0, in: ranges), 1)
        XCTAssertEqual(SpeakerPlaybackPlan.position(from: 2, in: ranges), 2)
        XCTAssertEqual(SpeakerPlaybackPlan.position(from: 4, in: ranges), 20)
        XCTAssertEqual(SpeakerPlaybackPlan.position(from: 10, in: ranges), 20)
        XCTAssertNil(SpeakerPlaybackPlan.position(from: 24, in: ranges))
    }

    // MARK: - Names across detection runs

    func testNamesFollowTheVoiceToItsNewSpeakerNumber() {
        let old = transcript([segment("A", 0, 10, "S1"), segment("B", 10, 20, "S2")])
        var names = SpeakerNameTable(transcriptRevision: old.revision)
        names.setName("Anna", for: "S1")
        names.setName("Ben", for: "S2")
        // The new run splits Anna's time between two speakers, so Ben gets another number.
        let new = transcript([
            segment("A1", 0, 7, "S1"),
            segment("A2", 7, 10, "S2"),
            segment("B", 10, 20, "S3"),
        ])

        let carried = SpeakerCarryOver.names(from: old, names: names, to: new)

        XCTAssertEqual(carried.names?.transcriptRevision, new.revision)
        XCTAssertEqual(carried.names?.displayName(for: "S1"), "Anna")
        XCTAssertNil(carried.names?.displayName(for: "S2"))
        XCTAssertEqual(carried.names?.displayName(for: "S3"), "Ben")
        XCTAssertTrue(carried.lost.isEmpty)
    }

    func testNameIsLostWhenNoNewSpeakerIsMostlyThatVoice() {
        let old = transcript([segment("A", 0, 10, "S1"), segment("B", 10, 20, "S2")])
        var names = SpeakerNameTable(transcriptRevision: old.revision)
        names.setName("Anna", for: "S1")
        names.setName("Ben", for: "S2")
        let new = transcript([segment("All", 0, 20, "S1")])

        let carried = SpeakerCarryOver.names(from: old, names: names, to: new)

        XCTAssertNil(carried.names)
        XCTAssertEqual(carried.lost, ["Anna", "Ben"])
    }

    // MARK: - Text edits

    func testEditingAParagraphReplacesItsSegmentsAndKeepsTimesAndSpeaker() {
        let original = transcript([
            segment("Helo.", 0, 1, "S1"),
            segment("Wrold.", 1, 2, "S1"),
            segment("Reply.", 2, 3, "S2"),
        ])

        let edited = original.replacingText(ofSegmentsIn: 0..<2, with: "  Hello. World. ")

        XCTAssertEqual(edited.revision, original.revision)
        XCTAssertEqual(edited.segments.map(\.text), ["Hello. World.", "Reply."])
        XCTAssertEqual(edited.segments[0].start, 0)
        XCTAssertEqual(edited.segments[0].end, 2)
        XCTAssertEqual(edited.segments[0].speakerID, "S1")
        XCTAssertEqual(edited.joinedText, "Hello. World. Reply.")
        XCTAssertEqual(original.replacingText(ofSegmentsIn: 0..<2, with: " ").segments.map(\.text), ["Reply."])
    }

    // MARK: - Export

    /// The default name of the unnamed second speaker in the app's language.
    private var unnamed: String { SpeakerTranscriptPresentation.defaultName(for: "S2") }

    private var exportTranscript: SpeakerTranscript {
        transcript([segment("Good morning.", 0, 1.5, "S1"), segment("Morning.", 65, 66.25, "S2")])
    }

    func testPlainTextAndMarkdownExportUseNamesAndTimes() {
        let transcript = exportTranscript
        var names = SpeakerNameTable(transcriptRevision: transcript.revision)
        names.setName("Anna", for: "S1")

        XCTAssertEqual(
            SpeakerTranscriptExporter.content(of: transcript, names: names, title: "Meeting", format: .plainText),
            "[0:00] Anna: Good morning.\n\n[1:05] \(unnamed): Morning."
        )
        XCTAssertEqual(
            SpeakerTranscriptExporter.content(of: transcript, names: names, title: "Meeting", format: .markdown),
            "# Meeting\n\n**Anna** (0:00)\n\nGood morning.\n\n**\(unnamed)** (1:05)\n\nMorning."
        )
    }

    func testSubtitleExportPrefixesEachCueWithTheSpeaker() {
        let transcript = exportTranscript
        var names = SpeakerNameTable(transcriptRevision: transcript.revision)
        names.setName("Anna", for: "S1")

        let srt = SpeakerTranscriptExporter.content(of: transcript, names: names, title: nil, format: .srt)
        let vtt = SpeakerTranscriptExporter.content(of: transcript, names: names, title: nil, format: .vtt)

        XCTAssertEqual(
            srt,
            "1\n00:00:00,000 --> 00:00:01,500\nAnna: Good morning.\n\n2\n00:01:05,000 --> 00:01:06,250\n\(unnamed): Morning."
        )
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.500\nAnna: Good morning."))
    }

    func testJSONExportListsSpeakersAndSegments() throws {
        let transcript = exportTranscript
        var names = SpeakerNameTable(transcriptRevision: transcript.revision)
        names.setName("Anna", for: "S1")

        let json = SpeakerTranscriptExporter.content(of: transcript, names: names, title: "Meeting", format: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let speakers = try XCTUnwrap(object["speakers"] as? [[String: String]])
        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])

        XCTAssertEqual(object["title"] as? String, "Meeting")
        XCTAssertEqual(speakers, [["id": "S1", "name": "Anna"], ["id": "S2", "name": unnamed]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1]["speaker"] as? String, "S2")
        XCTAssertEqual(segments[1]["start"] as? Double, 65)
    }
}

final class SpeakerWordAlignmentTests: XCTestCase {
    private func words(_ text: String, from start: TimeInterval, step: TimeInterval = 0.5) -> [TranscriptionWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptionWord(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + step - 0.05)
        }
    }

    func testSentenceIsSplitWhereTheSpeakerChangesBetweenWords() {
        let sentence = SpeakerTranscriptSegment(text: "Shall we start now? Yes, let us begin.", start: 0, end: 4)
        let turns = [
            SpeakerTurn(speakerID: "S1", start: 0, end: 2),
            SpeakerTurn(speakerID: "S2", start: 2, end: 4),
        ]

        let segments = SpeakerAlignment.segments(
            sentences: [sentence],
            words: words(sentence.text, from: 0),
            turns: turns
        )

        XCTAssertEqual(segments.map(\.text), ["Shall we start now?", "Yes, let us begin."])
        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[1].start, 2)
        XCTAssertEqual(segments[1].end, 4)
    }

    func testSingleStrayWordDoesNotSplitASentence() {
        let sentence = SpeakerTranscriptSegment(text: "One two three four five six", start: 0, end: 3)
        let turns = [
            SpeakerTurn(speakerID: "S1", start: 0, end: 1.5),
            SpeakerTurn(speakerID: "S2", start: 1.5, end: 2),
            SpeakerTurn(speakerID: "S1", start: 2, end: 3),
        ]

        let segments = SpeakerAlignment.segments(sentences: [sentence], words: words(sentence.text, from: 0), turns: turns)

        XCTAssertEqual(segments.map(\.text), ["One two three four five six"])
        XCTAssertEqual(segments.map(\.speakerID), ["S1"])
    }

    func testSentencesStaySeparateSegmentsForParagraphs() {
        let sentences = [
            SpeakerTranscriptSegment(text: "First sentence here.", start: 0, end: 1.5),
            SpeakerTranscriptSegment(text: "Second sentence here.", start: 1.5, end: 3),
        ]
        let turns = [SpeakerTurn(speakerID: "S1", start: 0, end: 3)]
        let allWords = words(sentences[0].text, from: 0) + words(sentences[1].text, from: 1.5)

        let segments = SpeakerAlignment.segments(sentences: sentences, words: allWords, turns: turns)

        XCTAssertEqual(segments.map(\.text), sentences.map(\.text))
        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S1"])
    }

    func testWithoutWordsWholeSentencesAreAssigned() {
        let sentence = SpeakerTranscriptSegment(text: "Shall we start now? Yes, let us begin.", start: 0, end: 4)
        let turns = [
            SpeakerTurn(speakerID: "S1", start: 0, end: 2.5),
            SpeakerTurn(speakerID: "S2", start: 2.5, end: 4),
        ]

        let segments = SpeakerAlignment.segments(sentences: [sentence], words: [], turns: turns)

        XCTAssertEqual(segments.map(\.text), [sentence.text])
        XCTAssertEqual(segments.map(\.speakerID), ["S1"])
    }
}

@MainActor
final class SpeakerWorkspaceModelTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!
    private let recordID = UUID()

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        history = HistoryService(appSupportDirectory: directory)
    }

    override func tearDown() async throws {
        history = nil
        TestSupport.remove(directory)
    }

    private func makeModel(words: [TranscriptionWord] = []) throws -> SpeakerWorkspaceModel {
        try SpeakerAudioWriter.writeAAC(
            samples: [Float](repeating: 0, count: 16_000),
            to: history.speakerAudioFileURL(forRecordID: recordID)
        )
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "Good morning everyone.", start: 0, end: 2, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Shall we start now? Yes, let us begin.", start: 2, end: 6, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Fine.", start: 6, end: 7, speakerID: "S2"),
        ])
        XCTAssertTrue(history.addSpeakerRecord(
            id: recordID,
            text: transcript.joinedText,
            title: "Meeting",
            source: .recorder,
            durationSeconds: 7,
            language: "en",
            engineUsed: "test",
            timedText: [],
            granularity: .segment,
            words: words,
            transcript: transcript
        ))
        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        return SpeakerWorkspaceModel(recordID: recordID, historyService: history)
    }

    func testAssignMergeAndEditAreStoredAndUndone() throws {
        let model = try makeModel()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        model.assign(turns: [1], to: "S1", undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(model.speakerIDs, ["S1"])
        XCTAssertEqual(history.record(withID: recordID)?.speakerTranscript?.speakerIDs, ["S1"])

        undoManager.undo()
        XCTAssertEqual(model.speakerIDs, ["S1", "S2"])
        XCTAssertEqual(model.name(of: "S1"), "Anna")

        undoManager.beginUndoGrouping()
        model.edit(model.rows[0].paragraph, text: "Good morning, everyone. Shall we start? Yes.", undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(history.record(withID: recordID)?.finalText, "Good morning, everyone. Shall we start? Yes. Fine.")

        undoManager.undo()
        XCTAssertEqual(
            history.record(withID: recordID)?.finalText,
            "Good morning everyone. Shall we start now? Yes, let us begin. Fine."
        )

        undoManager.beginUndoGrouping()
        model.merge("S2", into: "S1", undoManager: undoManager)
        undoManager.endUndoGrouping()
        XCTAssertEqual(model.turns.count, 1)
        XCTAssertEqual(model.name(of: "S1"), "Anna")
    }

    func testSplitAtAPositionCutsBeforeTheWordSpokenThere() throws {
        let sentence = "Shall we start now? Yes, let us begin."
        let words = sentence.split(separator: " ").enumerated().map { index, word in
            TranscriptionWord(text: String(word), start: 2 + Double(index) * 0.5, end: 2.45 + Double(index) * 0.5)
        }
        let model = try makeModel(words: words)

        // 4.1 s is inside "Yes," (4.0–4.45), the fifth word.
        model.split(at: 4.1, to: nil, undoManager: nil)

        let transcript = try XCTUnwrap(history.record(withID: recordID)?.speakerTranscript)
        XCTAssertEqual(transcript.segments.map(\.text), [
            "Good morning everyone.", "Shall we start now?", "Yes, let us begin.", "Fine.",
        ])
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S1", "S2", "S3"])
        XCTAssertEqual(model.name(of: "S1"), "Anna")
    }

    func testSplitWithoutWordTimingCutsAtAWordByTextPosition() throws {
        let model = try makeModel()

        model.split(at: 4.1, to: "S2", undoManager: nil)

        let transcript = try XCTUnwrap(history.record(withID: recordID)?.speakerTranscript)
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S1", "S2", "S2"])
        XCTAssertEqual(
            transcript.segments[1].text + " " + transcript.segments[2].text,
            "Shall we start now? Yes, let us begin."
        )
        XCTAssertFalse(transcript.segments[2].text.hasPrefix(" "))
    }

    func testSoloAndMuteDecideWhichSpeakersAreAudible() throws {
        let model = try makeModel()

        model.toggleSolo("S2")
        XCTAssertFalse(model.isAudible("S1"))
        XCTAssertTrue(model.isAudible("S2"))

        model.toggleMute("S2")
        XCTAssertTrue(model.soloedSpeakers.isEmpty)
        XCTAssertTrue(model.isAudible("S1"))
        XCTAssertFalse(model.isAudible("S2"))

        model.toggleMute("S1")
        // Everyone muted plays all rather than nothing.
        XCTAssertTrue(model.isAudible("S1"))
    }

    func testAnEditThatRemovesAllTextIsRejected() throws {
        _ = try makeModel()
        let transcript = try XCTUnwrap(history.record(withID: recordID)?.speakerTranscript)
        let emptied = transcript.replacingText(ofSegmentsIn: 0..<transcript.segments.count, with: " ")

        XCTAssertFalse(history.updateSpeakerTranscript(emptied, names: nil, forRecordID: recordID, updatesText: true))

        let record = try XCTUnwrap(history.record(withID: recordID))
        XCTAssertEqual(record.speakerTranscript, transcript)
        XCTAssertEqual(record.finalText, "Good morning everyone. Shall we start now? Yes, let us begin. Fine.")
    }

    func testSpeakerNamedAsTheUserIsOwnSpeech() throws {
        let model = try makeModel()
        XCTAssertFalse(model.isOwnSpeaker("S1"))
        XCTAssertFalse(model.isOwnSpeaker("S2"))

        let me = String(localized: "speakers.me")
        history.setSpeakerName(" \(me.lowercased()) ", for: "S2", inRecordID: recordID)
        model.reload()

        XCTAssertTrue(model.isOwnSpeaker("S2"))
        XCTAssertFalse(model.isOwnSpeaker("S1"))
    }
}

final class SpeakerTimedWordsTests: XCTestCase {
    private func paragraph(_ text: String, start: TimeInterval, end: TimeInterval) -> SpeakerParagraph {
        SpeakerParagraph(turnIndex: 0, speakerID: "S1", start: start, end: end, text: text, segmentRange: 0..<1)
    }

    func testWordsOfAnotherEngineGiveTheirTimesDespiteCaseAndPunctuation() {
        let paragraph = paragraph("herzlich willkommen bei welt tv", start: 0, end: 20)
        let words = [
            TranscriptionWord(text: "Herzlich", start: 11.0, end: 11.5),
            TranscriptionWord(text: "willkommen", start: 11.7, end: 12.2),
            TranscriptionWord(text: "bei", start: 16.0, end: 16.1),
            TranscriptionWord(text: "Welt", start: 16.2, end: 16.4),
            TranscriptionWord(text: "TV.", start: 16.5, end: 16.9),
        ]

        let timed = SpeakerTranscriptPresentation.timedWords(of: paragraph, segments: [], words: words)

        XCTAssertEqual(timed.map(\.text), ["herzlich", "willkommen", "bei", "welt", "tv"])
        XCTAssertEqual(timed.map(\.start), [11.0, 11.7, 16.0, 16.2, 16.5])
    }

    func testWordsTheOtherEngineHeardDifferentlyAreSpreadBetweenTheirNeighbours() {
        // "vier" was heard as "4" and "dem" is missing: both lie between "unter" and "Kolumnisten".
        let paragraph = paragraph("unter vier dem Kolumnisten Talk", start: 10, end: 20)
        let words = [
            TranscriptionWord(text: "Unter", start: 13.0, end: 13.3),
            TranscriptionWord(text: "4", start: 14.0, end: 14.1),
            TranscriptionWord(text: "Kolumnisten", start: 16.0, end: 16.6),
            TranscriptionWord(text: "Talk", start: 17.0, end: 17.3),
        ]

        let timed = SpeakerTranscriptPresentation.timedWords(of: paragraph, segments: [], words: words)

        XCTAssertEqual(timed.map(\.start), [13.0, 14.0, 15.0, 16.0, 17.0])
    }

    func testARepeatedWordDoesNotPullLaterWordsBackToTheStart() {
        let paragraph = paragraph("die Reform und die Wahl", start: 0, end: 10)
        let words = [
            TranscriptionWord(text: "Reform", start: 2, end: 2.5),
            TranscriptionWord(text: "und", start: 3, end: 3.2),
            TranscriptionWord(text: "die", start: 4, end: 4.2),
            TranscriptionWord(text: "Wahl", start: 5, end: 5.5),
        ]

        let timed = SpeakerTranscriptPresentation.timedWords(of: paragraph, segments: [], words: words)

        XCTAssertEqual(Array(timed.map(\.start).dropFirst()), [2, 3, 4, 5])
        XCTAssertLessThanOrEqual(timed[0].start, 2)
    }

    func testWithoutWordTimingTimesAreSpreadOverEachSegment() {
        let segments = [
            SpeakerTranscriptSegment(text: "eins zwei", start: 0, end: 2, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "drei vier", start: 10, end: 12, speakerID: "S1"),
        ]
        let paragraph = SpeakerParagraph(
            turnIndex: 0, speakerID: "S1", start: 0, end: 12, text: "eins zwei drei vier", segmentRange: 0..<2
        )

        let timed = SpeakerTranscriptPresentation.timedWords(of: paragraph, segments: segments, words: [])

        XCTAssertEqual(timed.map(\.text), ["eins", "zwei", "drei", "vier"])
        XCTAssertEqual(timed[0].start, 0, accuracy: 0.01)
        XCTAssertEqual(timed[2].start, 10, accuracy: 0.01)
        XCTAssertGreaterThan(timed[3].start, 10)
    }
}
