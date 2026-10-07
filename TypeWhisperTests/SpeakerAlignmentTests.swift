import XCTest
@testable import TypeWhisper

final class SpeakerAlignmentTests: XCTestCase {
    private let transcript = "Let's start with the budget. I have the numbers here. Great, thanks."

    private var words: [TimedTextEntry] {
        TimedTextEntry.map(
            textParts: [
                ("Let's", 0.0, 0.3), ("start", 0.3, 0.6), ("with", 0.6, 0.8), ("the", 0.8, 0.9), ("budget.", 0.9, 1.4),
                ("I", 2.0, 2.1), ("have", 2.1, 2.3), ("the", 2.3, 2.4), ("numbers", 2.4, 2.8), ("here.", 2.8, 3.1),
                ("Great,", 3.6, 3.9), ("thanks.", 3.9, 4.3),
            ],
            in: transcript
        )
    }

    func testNormalizedTurnsNumberSpeakersByFirstAppearance() {
        let turns = SpeakerAlignment.normalizedTurns([
            SpeakerTurn(speakerID: "S3", start: 5, end: 6),
            SpeakerTurn(speakerID: "S7", start: 0, end: 1),
            SpeakerTurn(speakerID: "S3", start: 2, end: 3),
            SpeakerTurn(speakerID: "S7", start: 4, end: 4),
        ])

        XCTAssertEqual(turns.map(\.speakerID), ["S1", "S2", "S2"])
        XCTAssertEqual(turns.map(\.start), [0, 2, 5])
    }

    func testWordsSplitAtSpeakerChangesAndKeepPunctuation() {
        let segments = SpeakerAlignment.segments(
            words: words,
            turns: [
                SpeakerTurn(speakerID: "S1", start: 0, end: 1.5),
                SpeakerTurn(speakerID: "S2", start: 1.9, end: 3.2),
                SpeakerTurn(speakerID: "S1", start: 3.5, end: 4.4),
            ],
            transcript: transcript
        )

        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S2", "S1"])
        XCTAssertEqual(segments.map(\.text), ["Let's start with the budget.", "I have the numbers here.", "Great, thanks."])
        XCTAssertEqual(segments.map(\.start), [0, 2.0, 3.6])
        XCTAssertEqual(segments.map(\.end), [1.4, 3.1, 4.3])
        XCTAssertEqual(segments.map(\.speakerConfidence), [1, 1, 1])
    }

    func testWordNearATurnTakesThatSpeakerWithLowerConfidence() {
        let segments = SpeakerAlignment.segments(
            words: words,
            turns: [
                SpeakerTurn(speakerID: "S1", start: 0, end: 1.5),
                // "I" (2.0–2.1) starts 0.5 s after this turn ends.
                SpeakerTurn(speakerID: "S2", start: 2.15, end: 3.2),
                SpeakerTurn(speakerID: "S1", start: 3.5, end: 4.4),
            ],
            transcript: transcript
        )

        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S2", "S1"])
        // "I" is attributed through proximity, the other four words overlap.
        XCTAssertEqual(segments[1].speakerConfidence ?? 0, 0.8, accuracy: 0.001)
    }

    func testWordsFarFromAnyTurnInheritThePreviousSpeaker() {
        let segments = SpeakerAlignment.segments(
            words: words,
            turns: [
                SpeakerTurn(speakerID: "S1", start: 0, end: 1.5),
                SpeakerTurn(speakerID: "S2", start: 2.0, end: 2.2),
            ],
            transcript: transcript
        )

        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(segments[1].text, "I have the numbers here. Great, thanks.")
        XCTAssertEqual(segments[1].speakerConfidence ?? 0, 2.0 / 7.0, accuracy: 0.001)
    }

    func testLeadingWordsWithoutSpeakerTakeTheFirstAssignedSpeaker() {
        let segments = SpeakerAlignment.segments(
            words: words,
            turns: [SpeakerTurn(speakerID: "S2", start: 2.0, end: 4.4)],
            transcript: transcript
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerID, "S2")
        XCTAssertEqual(segments[0].text, transcript)
    }

    func testSegmentsCoverTheWholeTranscriptIncludingLeadingText() {
        let text = "Okay. So the plan works."
        let timed = TimedTextEntry.map(
            textParts: [("So", 1.0, 1.2), ("the", 1.2, 1.3), ("plan", 1.3, 1.6), ("works.", 1.6, 2.0)],
            in: text
        )

        let segments = SpeakerAlignment.segments(
            words: timed,
            turns: [SpeakerTurn(speakerID: "S1", start: 0.8, end: 2.2)],
            transcript: text
        )

        XCTAssertEqual(segments.map(\.text), [text])
    }

    func testSegmentTimedEnginesAssignWholeSegmentsByLargestOverlap() {
        let segments = SpeakerAlignment.segments(
            segments: [
                SpeakerTranscriptSegment(text: "First.", start: 0, end: 4),
                SpeakerTranscriptSegment(text: "Second.", start: 4, end: 8),
                SpeakerTranscriptSegment(text: "Third.", start: 20, end: 22),
            ],
            turns: [
                SpeakerTurn(speakerID: "S1", start: 0, end: 5),
                SpeakerTurn(speakerID: "S2", start: 5, end: 8),
            ]
        )

        XCTAssertEqual(segments.map(\.speakerID), ["S1", "S2", "S2"])
        XCTAssertEqual(segments.map(\.speakerConfidence), [1, 1, 0])
    }

    func testNoTurnsOrWordsProduceNoSegments() {
        XCTAssertTrue(SpeakerAlignment.segments(words: words, turns: [], transcript: transcript).isEmpty)
        XCTAssertTrue(SpeakerAlignment.segments(
            words: [],
            turns: [SpeakerTurn(speakerID: "S1", start: 0, end: 1)],
            transcript: transcript
        ).isEmpty)
    }
}

final class SpeakerTranscriptBuilderTests: XCTestCase {
    private let turns = [
        SpeakerTurn(speakerID: "S1", start: 0, end: 2),
        SpeakerTurn(speakerID: "S2", start: 2, end: 4),
    ]

    func testWordTimingBuildsWordLevelSegments() throws {
        let text = "Hello there. Hi back."
        let words = TimedTextEntry.map(
            textParts: [("Hello", 0.1, 0.5), ("there.", 0.5, 1.0), ("Hi", 2.2, 2.5), ("back.", 2.5, 3.0)],
            in: text
        )

        let transcript = try XCTUnwrap(SpeakerAlignment.transcript(
            text: text, timedText: words, granularity: .word, turns: turns
        ))

        XCTAssertEqual(transcript.segments.map(\.text), ["Hello there.", "Hi back."])
        XCTAssertEqual(transcript.speakerIDs, ["S1", "S2"])
        XCTAssertEqual(transcript.source, .localDiarizer)
        XCTAssertTrue(transcript.isValid)
    }

    func testSegmentTimingAssignsWholeSegments() throws {
        let text = "Hello there. Hi back."
        let segments = TimedTextEntry.map(
            textParts: [("Hello there.", 0.1, 1.9), ("Hi back.", 2.1, 3.9)],
            in: text
        )

        let transcript = try XCTUnwrap(SpeakerAlignment.transcript(
            text: text, timedText: segments, granularity: .segment, turns: turns
        ))

        XCTAssertEqual(transcript.segments.map(\.speakerID), ["S1", "S2"])
    }

    func testMissingTimingOrSpeakersGivesNoTranscript() {
        XCTAssertNil(SpeakerAlignment.transcript(text: "Hi", timedText: [], granularity: .none, turns: turns))
        XCTAssertNil(SpeakerAlignment.transcript(
            text: "Hi",
            timedText: TimedTextEntry.map(textParts: [("Hi", 0, 1)], in: "Hi"),
            granularity: .word,
            turns: []
        ))
    }

    func testSpeakerNumberingFollowsFirstAppearance() {
        let numbering = SpeakerAlignment.speakerNumbering([
            SpeakerTurn(speakerID: "B", start: 3, end: 4),
            SpeakerTurn(speakerID: "A", start: 1, end: 2),
            SpeakerTurn(speakerID: "C", start: 5, end: 5),
        ])

        XCTAssertEqual(numbering, ["A": "S1", "B": "S2"])
    }
}

final class SpeakerTranscriptTests: XCTestCase {
    func testSpeakerIDsFollowFirstAppearanceAndSpeakingTimeSumsSegments() {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "a", start: 0, end: 2, speakerID: "S2"),
                SpeakerTranscriptSegment(text: "b", start: 2, end: 3, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "c", start: 3, end: 6, speakerID: "S2"),
                SpeakerTranscriptSegment(text: "d", start: 6, end: 7),
            ]
        )

        XCTAssertEqual(transcript.speakerIDs, ["S2", "S1"])
        XCTAssertEqual(transcript.speakingTime(of: "S2"), 5)
    }

    func testValidationRejectsBadSpeakerIDsTimesAndConfidence() {
        func transcript(_ segment: SpeakerTranscriptSegment) -> SpeakerTranscript {
            SpeakerTranscript(source: .localDiarizer, segments: [segment])
        }

        XCTAssertTrue(transcript(.init(text: "", start: 0, end: 1, speakerID: "S12", speakerConfidence: 0.5)).isValid)
        XCTAssertTrue(transcript(.init(text: "", start: 0, end: 1)).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 0, end: 1, speakerID: "S0")).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 0, end: 1, speakerID: "S1000")).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 0, end: 1, speakerID: "Speaker A")).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 2, end: 1, speakerID: "S1")).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 0, end: .infinity)).isValid)
        XCTAssertFalse(transcript(.init(text: "", start: 0, end: 1, speakerConfidence: 1.5)).isValid)
    }

    func testSegmentsWithoutSpeakerFieldsDecodeFromLegacyJSON() throws {
        let data = Data(#"{"text":"Hi","start":0,"end":1}"#.utf8)
        let segment = try JSONDecoder().decode(SpeakerTranscriptSegment.self, from: data)

        XCTAssertEqual(segment, SpeakerTranscriptSegment(text: "Hi", start: 0, end: 1))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(segment), as: UTF8.self).contains("speaker"))
    }

    func testNameTableTrimsLimitsAndClearsNames() {
        let revision = UUID()
        var names = SpeakerNameTable(transcriptRevision: revision)

        names.setName("  Anna  ", for: "S2")
        names.setName(String(repeating: "x", count: 150), for: "S1")
        XCTAssertEqual(names.displayName(for: "S2"), "Anna")
        XCTAssertEqual(names.displayName(for: "S1")?.count, SpeakerNameTable.maximumNameLength)
        XCTAssertEqual(names.entries.map(\.speakerID), ["S1", "S2"])

        names.setName("   ", for: "S2")
        XCTAssertNil(names.displayName(for: "S2"))
    }

    func testNamesApplyOnlyToTheirTranscriptRevision() {
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [])
        XCTAssertTrue(SpeakerNameTable(transcriptRevision: transcript.revision).applies(to: transcript))
        XCTAssertFalse(SpeakerNameTable(transcriptRevision: UUID()).applies(to: transcript))
    }
}

final class SpeakerTranscriptPresentationTests: XCTestCase {
    private let transcript = SpeakerTranscript(
        source: .localDiarizer,
        segments: [
            SpeakerTranscriptSegment(text: "Hello.", start: 0, end: 1, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Still me.", start: 1, end: 2, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "uh", start: 2, end: 2.5),
            SpeakerTranscriptSegment(text: "Hi Anna.", start: 3, end: 4, speakerID: "S2"),
            SpeakerTranscriptSegment(text: "  ", start: 4, end: 5, speakerID: "S1"),
        ]
    )

    func testTurnsJoinConsecutiveSegmentsOfOneSpeaker() {
        let turns = SpeakerTranscriptPresentation.turns(of: transcript)

        XCTAssertEqual(turns.map(\.speakerID), ["S1", "S2"])
        XCTAssertEqual(turns.map(\.text), ["Hello. Still me. uh", "Hi Anna."])
        XCTAssertEqual(turns.map(\.start), [0, 3])
        XCTAssertEqual(turns.map(\.end), [2.5, 4])
        XCTAssertEqual(turns.map(\.index), [0, 1])
        XCTAssertEqual(turns.map(\.segmentRange), [0..<3, 3..<4])
    }

    func testAssigningATurnKeepsTheRevisionAndJoinsNeighbouringTurns() throws {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "One.", start: 0, end: 1, speakerID: "S1", speakerConfidence: 0.8),
                SpeakerTranscriptSegment(text: "Two.", start: 1, end: 2, speakerID: "S2", speakerConfidence: 0.6),
                SpeakerTranscriptSegment(text: "Three.", start: 2, end: 3, speakerID: "S1", speakerConfidence: 0.9),
            ]
        )
        let middle = SpeakerTranscriptPresentation.turns(of: transcript)[1]

        let corrected = transcript.assigning(segmentsIn: middle.segmentRange, to: "S1")

        XCTAssertEqual(corrected.revision, transcript.revision)
        XCTAssertEqual(corrected.speakerIDs, ["S1"])
        XCTAssertEqual(corrected.segments[1].speakerConfidence, 1)
        XCTAssertEqual(corrected.segments[0], transcript.segments[0])
        XCTAssertEqual(SpeakerTranscriptPresentation.turns(of: corrected).map(\.text), ["One. Two. Three."])
        XCTAssertTrue(corrected.isValid)

        let split = transcript.assigning(segmentsIn: 2..<10, to: try XCTUnwrap(transcript.unusedSpeakerID))
        XCTAssertEqual(split.speakerIDs, ["S1", "S2", "S3"])
    }

    func testMergingMovesEveryTurnOfOneSpeaker() {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "A.", start: 0, end: 1, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "B.", start: 1, end: 2, speakerID: "S2"),
                SpeakerTranscriptSegment(text: "C.", start: 2, end: 3, speakerID: "S3"),
                SpeakerTranscriptSegment(text: "D.", start: 3, end: 4, speakerID: "S2"),
            ],
            requestedSpeakerCount: 3
        )

        let merged = transcript.merging("S2", into: "S3")

        XCTAssertEqual(merged.revision, transcript.revision)
        XCTAssertEqual(merged.requestedSpeakerCount, 3)
        XCTAssertEqual(merged.segments.map(\.speakerID), ["S1", "S3", "S3", "S3"])
        XCTAssertEqual(merged.unusedSpeakerID, "S4")
        XCTAssertEqual(merged.speakingTime(of: "S3"), 3)

        let (renumbered, newSpeakerIDs) = merged.renumbered()
        XCTAssertEqual(renumbered.revision, transcript.revision)
        XCTAssertEqual(renumbered.segments.map(\.speakerID), ["S1", "S2", "S2", "S2"])
        XCTAssertEqual(newSpeakerIDs, ["S1": "S1", "S3": "S2"])
        XCTAssertEqual(transcript.renumbered().transcript, transcript)
    }

    func testRenamingSpeakersMovesNamesAndDropsRemovedSpeakers() {
        let profileID = UUID()
        var names = SpeakerNameTable(transcriptRevision: UUID())
        names.setName("Anna", for: "S1")
        names.setName("Ben", for: "S2")
        names.setName("Carl", for: "S3", profileID: profileID)

        let renamed = names.renamingSpeakers(["S1": "S1", "S3": "S2"])

        XCTAssertEqual(renamed.transcriptRevision, names.transcriptRevision)
        XCTAssertEqual(renamed.entries.map(\.displayName), ["Anna", "Carl"])
        XCTAssertEqual(renamed.profileID(for: "S2"), profileID)
        XCTAssertNil(renamed.displayName(for: "S3"))
    }

    func testPlainTextUsesNamesAndDefaultNames() {
        var names = SpeakerNameTable(transcriptRevision: transcript.revision)
        names.setName("Anna", for: "S1")

        XCTAssertEqual(
            SpeakerTranscriptPresentation.plainText(of: transcript, names: names),
            "Anna: Hello. Still me. uh\n\n\(SpeakerTranscriptPresentation.defaultName(for: "S2")): Hi Anna."
        )
    }

    func testActiveTurnIsTheLastStartedTurn() {
        let turns = SpeakerTranscriptPresentation.turns(of: transcript)

        XCTAssertNil(SpeakerTranscriptPresentation.activeTurn(in: [], at: 1))
        XCTAssertEqual(SpeakerTranscriptPresentation.activeTurn(in: turns, at: 2.8)?.speakerID, "S1")
        XCTAssertEqual(SpeakerTranscriptPresentation.activeTurn(in: turns, at: 3)?.speakerID, "S2")
    }

    func testSplittingATurnGivesTheRestToAnotherSpeaker() throws {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "Also wir, ich bin Marco. Ich bin Thomas.", start: 0.9, end: 7.4, speakerID: "S1", speakerConfidence: 1),
                SpeakerTranscriptSegment(text: "Und ich wohne in Zeuthen.", start: 7.4, end: 9, speakerID: "S1", speakerConfidence: 1),
                SpeakerTranscriptSegment(text: "Ich bin Ilona.", start: 9, end: 10, speakerID: "S2", speakerConfidence: 1),
            ]
        )
        let turn = try XCTUnwrap(SpeakerTranscriptPresentation.turns(of: transcript).first)

        let points = SpeakerTranscriptPresentation.splitPoints(of: turn, in: transcript)
        XCTAssertEqual(points.map(\.text), ["Ich bin Thomas.", "Und ich wohne in Zeuthen."])
        let thomas = points[0]
        let timedText = TimedTextEntry.map(
            textParts: [("Also", 0.9, 1.2), ("wir,", 1.2, 1.5), ("ich", 2, 2.2), ("bin", 2.2, 2.4), ("Marco.", 2.4, 3),
                        ("Ich", 5.2, 5.4), ("bin", 5.4, 5.6), ("Thomas.", 5.6, 6.4)],
            in: "Also wir, ich bin Marco. Ich bin Thomas."
        )
        let time = SpeakerTranscriptPresentation.time(of: thomas, in: transcript, timedText: timedText)
        XCTAssertEqual(time, 5.2)

        let split = transcript.splitting(turn, at: thomas, time: time, to: "S3")

        XCTAssertEqual(split.revision, transcript.revision)
        XCTAssertEqual(split.segments.map(\.text), ["Also wir, ich bin Marco.", "Ich bin Thomas.", "Und ich wohne in Zeuthen.", "Ich bin Ilona."])
        XCTAssertEqual(split.segments.map(\.speakerID), ["S1", "S3", "S3", "S2"])
        XCTAssertEqual(split.segments[0].end, 5.2)
        XCTAssertEqual(split.segments[1].start, 5.2)
        XCTAssertTrue(split.isValid)
        XCTAssertEqual(split.renumbered().transcript.speakerIDs, ["S1", "S2", "S3"])
    }

    func testSplitPointsFallBackToWordsForASingleSentence() throws {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [SpeakerTranscriptSegment(text: "ja genau so", start: 0, end: 3, speakerID: "S1")]
        )
        let turn = try XCTUnwrap(SpeakerTranscriptPresentation.turns(of: transcript).first)

        let points = SpeakerTranscriptPresentation.splitPoints(of: turn, in: transcript)

        XCTAssertEqual(points.map(\.text), ["genau", "so"])
        XCTAssertEqual(SpeakerTranscriptPresentation.time(of: points[0], in: transcript, timedText: []), 0.8182, accuracy: 0.001)
    }

    func testSharesAddUpAndStartWithTheLongestSpeaker() {
        let turns = [
            SpeakerTranscriptTurn(index: 0, speakerID: "S1", start: 0, end: 10, text: "A", segmentRange: 0..<1),
            SpeakerTranscriptTurn(index: 1, speakerID: "S2", start: 10, end: 40, text: "B", segmentRange: 1..<2),
            SpeakerTranscriptTurn(index: 2, speakerID: "S1", start: 40, end: 50, text: "C", segmentRange: 2..<3),
        ]

        let shares = SpeakerTranscriptPresentation.shares(of: turns)

        XCTAssertEqual(shares.map(\.speakerID), ["S2", "S1"])
        XCTAssertEqual(shares.map(\.seconds), [30, 20])
        XCTAssertEqual(shares[0].fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(shares.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertTrue(SpeakerTranscriptPresentation.shares(of: []).isEmpty)
    }

    func testSampleTurnIsTheSpeakersLongestTurn() {
        let turns = [
            SpeakerTranscriptTurn(index: 0, speakerID: "S1", start: 0, end: 2, text: "Short.", segmentRange: 0..<1),
            SpeakerTranscriptTurn(index: 1, speakerID: "S2", start: 2, end: 30, text: "Long other.", segmentRange: 1..<2),
            SpeakerTranscriptTurn(index: 2, speakerID: "S1", start: 30, end: 40, text: "Longest.", segmentRange: 2..<3),
            SpeakerTranscriptTurn(index: 3, speakerID: "S1", start: 40, end: 50, text: "Tie.", segmentRange: 3..<4),
        ]

        XCTAssertEqual(SpeakerTranscriptPresentation.sampleTurn(of: "S1", in: turns)?.index, 2)
        XCTAssertNil(SpeakerTranscriptPresentation.sampleTurn(of: "S3", in: turns))
    }

    func testSampleEndsWithTheLastWordSpokenInTheExcerpt() throws {
        let text = "Hello there. How are you"
        let turns = [SpeakerTranscriptTurn(index: 0, speakerID: "S1", start: 0, end: 14, text: text, segmentRange: 0..<1)]
        let timedText = TimedTextEntry.map(
            textParts: [("Hello", 0, 1), ("there.", 1, 2), ("How", 11, 12.4), ("are", 12.5, 13), ("you", 13, 14)],
            in: text
        )

        let sample = try XCTUnwrap(
            SpeakerTranscriptPresentation.sample(of: "S1", in: turns, timedText: timedText, granularity: .word)
        )

        XCTAssertEqual(sample.text, "Hello there. How…")
        XCTAssertEqual(sample.start, 0)
        XCTAssertEqual(sample.end, 12.4)
        XCTAssertEqual(sample.words.map(\.text), ["Hello", "there.", "How"])
        XCTAssertEqual(sample.words.last?.range, NSRange(location: 13, length: 3))

        for (entries, granularity) in [([], TimedTextGranularity.word), (timedText, .segment)] {
            let untimed = try XCTUnwrap(
                SpeakerTranscriptPresentation.sample(of: "S1", in: turns, timedText: entries, granularity: granularity)
            )
            XCTAssertEqual(untimed.text, text)
            XCTAssertEqual(untimed.end, 12)
            XCTAssertTrue(untimed.words.isEmpty)
        }
        XCTAssertNil(
            SpeakerTranscriptPresentation.sample(of: "S2", in: turns, timedText: timedText, granularity: .word)
        )
    }

    func testSampleIgnoresWordsFromElsewhereThatShareTheTime() throws {
        // A later chunk of a long file restarts its clock, so "you" at 3 s
        // belongs to a different place in the transcript.
        let recording = "Hello there. How are you. Later you said something."
        let timedText = TimedTextEntry.map(
            textParts: [
                ("Hello", 0, 1), ("there.", 1, 2), ("How", 2, 2.5), ("are", 2.5, 2.8), ("you.", 20, 21),
                ("Later", 1, 1.5), ("you", 3, 3.2), ("said", 3.2, 3.5), ("something.", 3.5, 4),
            ],
            in: recording
        )
        let turns = [SpeakerTranscriptTurn(
            index: 0, speakerID: "S1", start: 0, end: 21, text: "Hello there. How are you.", segmentRange: 0..<1
        )]

        let sample = try XCTUnwrap(
            SpeakerTranscriptPresentation.sample(of: "S1", in: turns, timedText: timedText, granularity: .word)
        )

        XCTAssertEqual(sample.words.map(\.text), ["Hello", "there.", "How", "are"])
        XCTAssertEqual(sample.text, "Hello there. How are…")
    }

    func testSampleStopsAtAJumpInOlderWordTiming() throws {
        let filler = String(repeating: "untimed ", count: 40)
        let recording = "Hello there. " + filler + "far away."
        let farAway = ("Hello there. " + filler) as NSString
        let timedText = [
            TimedTextEntry(text: "Hello", start: 0, end: 1, utf16Location: 0, utf16Length: 5),
            TimedTextEntry(text: "there.", start: 1, end: 2, utf16Location: 6, utf16Length: 6),
            TimedTextEntry(text: "far", start: 2, end: 3, utf16Location: farAway.length, utf16Length: 3),
        ]
        let turns = [SpeakerTranscriptTurn(
            index: 0, speakerID: "S1", start: 0, end: 30, text: recording, segmentRange: 0..<1
        )]

        let sample = try XCTUnwrap(
            SpeakerTranscriptPresentation.sample(of: "S1", in: turns, timedText: timedText, granularity: .word)
        )

        XCTAssertEqual(sample.words.map(\.text), ["Hello", "there."])
        XCTAssertEqual(sample.text, "Hello there.…")
    }

    func testNameSuggestionsMatchTypedTextAndSkipTakenNames() {
        let earlier = ["Anna", "Jörg", "Marco", "Annika", "Hanna"]

        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "", excluding: ["marco "]),
            ["Anna", "Jörg", "Annika"]
        )
        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "ann", excluding: []),
            ["Anna", "Annika", "Hanna"]
        )
        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "joerg", excluding: []),
            []
        )
        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "jorg", excluding: []),
            ["Jörg"]
        )
        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "Anna", excluding: []),
            ["Hanna"]
        )
        XCTAssertEqual(
            SpeakerTranscriptPresentation.nameSuggestions(from: earlier, matching: "anna", excluding: []),
            ["Anna", "Hanna"]
        )
    }

    func testTimestampsSwitchToHoursForLongMeetings() {
        XCTAssertEqual(SpeakerTranscriptPresentation.timestamp(65.9), "1:05")
        XCTAssertEqual(SpeakerTranscriptPresentation.timestamp(3_725), "1:02:05")
    }
}

final class SpeakerCountTests: XCTestCase {
    func testRequestedSpeakerCountIsKeptOnTheTranscript() throws {
        let text = "Hello there."
        let transcript = try XCTUnwrap(SpeakerAlignment.transcript(
            text: text,
            timedText: TimedTextEntry.map(textParts: [("Hello", 0, 0.5), ("there.", 0.5, 1)], in: text),
            granularity: .word,
            turns: [SpeakerTurn(speakerID: "S1", start: 0, end: 1)],
            requestedSpeakerCount: 3
        ))

        XCTAssertEqual(transcript.requestedSpeakerCount, 3)
        let decoded = try JSONDecoder().decode(SpeakerTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded, transcript)
    }

    func testTranscriptsWithoutRequestedCountDecodeAsAutomatic() throws {
        let data = Data(#"""
        {"revision":"7F0C2E3A-1B2C-4D5E-8F90-123456789ABC","source":{"kind":"local","engine":"fluidaudio-offline-diarizer"},"segments":[]}
        """#.utf8)

        XCTAssertNil(try JSONDecoder().decode(SpeakerTranscript.self, from: data).requestedSpeakerCount)
    }

    func testOfferedCountsStartAtTwo() {
        XCTAssertEqual(SpeakerTranscript.selectableSpeakerCounts.first, 2)
        XCTAssertEqual(SpeakerTranscript.selectableSpeakerCounts.last, 8)
    }
}
