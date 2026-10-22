import XCTest
@testable import TypeWhisper

final class VoiceProfileMatchingTests: XCTestCase {
    private let anna = UUID()
    private let ben = UUID()

    private func profile(
        _ id: UUID,
        _ name: String,
        _ embedding: [Float],
        model: String? = "model-a"
    ) -> VoiceProfile {
        VoiceProfile(
            id: id,
            name: name,
            embedding: embedding,
            embeddingModel: model,
            enrolledSeconds: 60,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testMatchesAssignEachProfileOnceAboveTheThreshold() {
        let profiles = [profile(anna, "Anna", [1, 0, 0]), profile(ben, "Ben", [0, 1, 0])]
        let matches = VoiceProfileMatching.matches(
            speakers: [
                "S1": [0.95, 0.05, 0],
                "S2": [0.9, 0.1, 0.1],
                "S3": [0.05, 1, 0],
                "S4": [0, 0, 1],
            ],
            embeddingModel: "model-a",
            speakingTime: { _ in 60 },
            profiles: profiles
        )

        XCTAssertEqual(matches["S1"]?.profileID, anna)
        XCTAssertNil(matches["S2"], "Anna is taken by the closer speaker")
        XCTAssertEqual(matches["S3"]?.profileID, ben)
        XCTAssertNil(matches["S4"], "below the threshold")
    }

    func testShortSpeechAndUnclearLeadsAreNotMatched() {
        let profiles = [profile(anna, "Anna", [1, 0.1, 0]), profile(ben, "Ben", [1, 0, 0.1])]

        XCTAssertTrue(VoiceProfileMatching.matches(
            speakers: ["S1": [1, 0.05, 0.05]],
            embeddingModel: "model-a",
            speakingTime: { _ in 60 },
            profiles: profiles
        ).isEmpty, "Anna and Ben score almost the same")
        XCTAssertTrue(VoiceProfileMatching.matches(
            speakers: ["S1": [1, 0, 0]],
            embeddingModel: "model-a",
            speakingTime: { _ in 10 },
            profiles: [profile(anna, "Anna", [1, 0, 0])]
        ).isEmpty, "too little speech")
    }

    func testOnlyProfilesOfTheSpeakersEmbeddingModelMatch() {
        let profiles = [
            profile(anna, "Anna", [1, 0, 0], model: "model-b"),
            profile(ben, "Ben", [0, 1, 0], model: nil),
        ]
        let speakers: [String: [Float]] = ["S1": [1, 0, 0], "S2": [0, 1, 0]]

        XCTAssertTrue(VoiceProfileMatching.matches(
            speakers: speakers,
            embeddingModel: "model-a",
            speakingTime: { _ in 60 },
            profiles: profiles
        ).isEmpty, "the same numbers from another model mean nothing")
        XCTAssertTrue(VoiceProfileMatching.matches(
            speakers: speakers,
            embeddingModel: nil,
            speakingTime: { _ in 60 },
            profiles: profiles
        ).isEmpty, "embeddings of an unknown model never match")
        XCTAssertEqual(VoiceProfileMatching.matches(
            speakers: speakers,
            embeddingModel: "model-b",
            speakingTime: { _ in 60 },
            profiles: profiles
        ).mapValues(\.profileID), ["S1": anna])
    }

    func testCorrectedEmbeddingsFollowMergesButNotSingleMovedTurns() throws {
        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "A.", start: 0, end: 20, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "B.", start: 20, end: 30, speakerID: "S2"),
                SpeakerTranscriptSegment(text: "C.", start: 30, end: 70, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "D.", start: 70, end: 100, speakerID: "S3"),
            ]
        )
        let embeddings: [String: [Float]] = ["S1": [1, 0], "S2": [0, 1], "S3": [0.5, 0.5]]

        let merged = VoiceProfileMatching.correctedEmbeddings(
            embeddings,
            from: transcript,
            to: transcript.merging("S2", into: "S1").renumbered().transcript
        )
        let s1 = try XCTUnwrap(merged["S1"])
        XCTAssertEqual(s1[0], 60 / 70, accuracy: 0.0001)
        XCTAssertEqual(s1[1], 10 / 70, accuracy: 0.0001)
        XCTAssertEqual(merged["S2"], [0.5, 0.5], "S3 is numbered S2 after the merge")

        let moved = VoiceProfileMatching.correctedEmbeddings(
            embeddings,
            from: transcript,
            to: transcript.assigning(segmentsIn: 0..<1, to: "S4")
        )
        XCTAssertEqual(moved["S1"], [1, 0], "S1 keeps most of its speech")
        XCTAssertNil(moved["S4"], "a speaker made from one moved turn has no known voice")

        let turn = try XCTUnwrap(SpeakerTranscriptPresentation.turns(of: transcript).last)
        let split = VoiceProfileMatching.correctedEmbeddings(
            embeddings,
            from: transcript,
            to: transcript.splitting(
                turn,
                at: SpeakerSplitPoint(segmentIndex: 3, utf16Offset: 0, text: "D."),
                time: 70,
                to: "S5"
            )
        )
        XCTAssertEqual(split["S1"], [1, 0], "a split with an extra segment keeps the other voices")
        XCTAssertEqual(split["S5"], [0.5, 0.5], "all of S3's speech went to S5")
    }
}

@MainActor
final class VoiceProfileStoreTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VoiceProfileStoreTests-\(UUID().uuidString)")

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testProfilesAndEmbeddingsPersistOutsideBackups() throws {
        let store = VoiceProfileStore(directoryURL: root)
        let profile = store.enroll(name: "Ben", embedding: [1, 0], model: "model-a", seconds: 30)
        store.enroll(name: "anna", embedding: [0, 1], model: "model-a", seconds: 30)
        let recordID = UUID()
        let revision = UUID()
        store.storeEmbeddings(["S1": [1, 0]], model: "model-a", forRecordID: recordID, revision: revision)

        store.learn(profileID: profile.id, embedding: [0, 1], model: "model-a", seconds: 10)
        store.rename(profileID: profile.id, to: "  Benjamin ")

        let reopened = VoiceProfileStore(directoryURL: root)
        XCTAssertEqual(reopened.profiles.map(\.name), ["anna", "Benjamin"])
        let learned = try XCTUnwrap(reopened.profile(withID: profile.id))
        XCTAssertEqual(learned.enrolledSeconds, 40)
        XCTAssertEqual(learned.embedding[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(reopened.embeddings(forRecordID: recordID, revision: revision), ["S1": [1, 0]])
        XCTAssertEqual(reopened.embeddingModel(forRecordID: recordID, revision: revision), "model-a")
        XCTAssertEqual(reopened.currentEmbeddingModel, "model-a")
        XCTAssertFalse(reopened.isOutdated(learned))
        XCTAssertTrue(reopened.embeddings(forRecordID: recordID, revision: UUID()).isEmpty)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        reopened.delete(profileID: profile.id)
        reopened.removeEmbeddings(exceptForRecordIDs: [])
        let emptied = VoiceProfileStore(directoryURL: root)
        XCTAssertEqual(emptied.profiles.map(\.name), ["anna"])
        XCTAssertTrue(emptied.embeddings(forRecordID: recordID, revision: revision).isEmpty)
    }

    func testAProfileOfAnotherModelIsOutdatedAndReplacedInsteadOfAveraged() throws {
        let store = VoiceProfileStore(directoryURL: root)
        let profile = store.enroll(name: "Ben", embedding: [1, 0], model: "model-a", seconds: 30)
        store.storeEmbeddings(["S1": [0, 1, 0]], model: "model-b", forRecordID: UUID(), revision: UUID())
        XCTAssertTrue(store.isOutdated(try XCTUnwrap(store.profile(withID: profile.id))))

        store.learn(profileID: profile.id, embedding: [0, 1, 0], model: "model-b", seconds: 10)

        let learned = try XCTUnwrap(store.profile(withID: profile.id))
        XCTAssertEqual(learned.embedding, [0, 1, 0])
        XCTAssertEqual(learned.embeddingModel, "model-b")
        XCTAssertEqual(learned.enrolledSeconds, 10)
        XCTAssertFalse(store.isOutdated(learned))
    }

    func testProfilesStoredWithoutAModelAreOutdated() throws {
        let file = root.appendingPathComponent("voice-profiles.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        try Data("""
        {"profiles": [{"id": "\(id.uuidString)", "name": "Ben", "embedding": [1, 0], "enrolledSeconds": 30,
          "createdAt": 0, "updatedAt": 0}], "recordings": []}
        """.utf8).write(to: file)

        let store = VoiceProfileStore(directoryURL: root)

        let profile = try XCTUnwrap(store.profile(withID: id))
        XCTAssertNil(profile.embeddingModel)
        XCTAssertTrue(store.isOutdated(profile))
    }
}


@MainActor
final class SpeakerVoiceProfileServiceTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!
    private var store: VoiceProfileStore!
    private var service: SpeakerVoiceProfileService!

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        history = HistoryService(appSupportDirectory: directory)
        store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles"))
        service = SpeakerVoiceProfileService(
            store: store,
            historyService: history
        )
    }

    override func tearDown() async throws {
        service = nil
        history = nil
        TestSupport.remove(directory)
    }

    /// A recording where S1 speaks 40 s, S2 30 s and S3 10 s, with their voices stored.
    @discardableResult
    private func addRecording(
        _ embeddings: [String: [Float]] = ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1]],
        model: String = "model-a"
    ) throws -> UUID {
        let id = UUID()
        try SpeakerAudioWriter.writeAAC(
            samples: [Float](repeating: 0, count: 16_000),
            to: history.speakerAudioFileURL(forRecordID: id)
        )
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "First.", start: 0, end: 40, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Second.", start: 40, end: 70, speakerID: "S2"),
            SpeakerTranscriptSegment(text: "Third.", start: 70, end: 80, speakerID: "S3"),
        ])
        XCTAssertTrue(history.addSpeakerRecord(
            id: id,
            text: transcript.joinedText,
            title: "Meeting",
            source: .recorder,
            durationSeconds: 80,
            language: "en",
            engineUsed: "test",
            timedText: [],
            granularity: .segment,
            transcript: transcript
        ))
        service.recordVoices(embeddings, model: model, of: transcript, recordID: id)
        return id
    }

    private func names(_ id: UUID) -> SpeakerNameTable? {
        history.record(withID: id)?.speakerNames
    }

    func testOnlyNamedSpeakersWithEnoughSpeechCanGetAProfile() throws {
        let id = try addRecording()
        XCTAssertEqual(service.state(of: "S1", inRecordID: id), .none, "unnamed")

        history.setSpeakerName("Anna", for: "S1", inRecordID: id)
        history.setSpeakerName("Carl", for: "S3", inRecordID: id)

        XCTAssertEqual(service.state(of: "S1", inRecordID: id), .canEnroll)
        XCTAssertEqual(service.state(of: "S3", inRecordID: id), .none, "10 s is too little speech")

        service.enroll("S3", inRecordID: id)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testEnrolledVoiceIsSuggestedInLaterRecordingsAndLearnsWhenConfirmed() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)

        let profile = try XCTUnwrap(store.profiles.first)
        XCTAssertEqual(profile.name, "Anna")
        XCTAssertEqual(profile.embedding, [1, 0, 0])
        XCTAssertEqual(profile.enrolledSeconds, 40)
        XCTAssertEqual(service.state(of: "S1", inRecordID: first), .linked)
        XCTAssertEqual(names(first)?.profileID(for: "S1"), profile.id)

        // In the next meeting Anna is the second speaker.
        let second = try addRecording(["S1": [0, 1, 0], "S2": [0.98, 0.05, 0], "S3": [0, 0, 1]])
        XCTAssertEqual(names(second)?.displayName(for: "S2"), "Anna")
        XCTAssertEqual(service.state(of: "S2", inRecordID: second), .suggestion)
        XCTAssertNil(names(second)?.displayName(for: "S1"))

        service.confirm("S2", inRecordID: second)
        XCTAssertEqual(service.state(of: "S2", inRecordID: second), .linked)
        XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 70)
        XCTAssertEqual(service.appearances(of: profile.id).map(\.recordID).sorted { $0.uuidString < $1.uuidString },
                       [first, second].sorted { $0.uuidString < $1.uuidString })
    }

    func testDeletingAProfileClearsItsSuggestionsAndKeepsConfirmedNames() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)
        let profileID = try XCTUnwrap(store.profiles.first?.id)
        let second = try addRecording()
        XCTAssertEqual(service.state(of: "S1", inRecordID: second), .suggestion)

        service.deleteProfile(profileID)

        XCTAssertNil(names(second)?.displayName(for: "S1"))
        XCTAssertEqual(names(first)?.displayName(for: "S1"), "Anna")
    }

    func testRejectingASuggestionClearsTheNameAndKeepsTheProfile() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)
        let second = try addRecording()
        XCTAssertEqual(service.state(of: "S1", inRecordID: second), .suggestion)

        service.reject("S1", inRecordID: second)

        XCTAssertNil(names(second)?.displayName(for: "S1"))
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
    }

    /// Issue #1558: enrolling, confirming and relearning suggest names in every
    /// stored recording again; a rejected profile must stay off that speaker.
    func testARejectedSuggestionDoesNotComeBackAfterLaterLearning() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)
        let anna = try XCTUnwrap(store.profiles.first?.id)
        let second = try addRecording()
        XCTAssertEqual(service.state(of: "S1", inRecordID: second), .suggestion)
        service.reject("S1", inRecordID: second)

        // Enrolling Ben in a third recording suggests names everywhere again.
        let third = try addRecording()
        history.setSpeakerName("Ben", for: "S2", inRecordID: third)
        service.enroll("S2", inRecordID: third)
        XCTAssertNil(names(second)?.displayName(for: "S1"), "the rejected profile is not suggested again")
        XCTAssertEqual(names(second)?.displayName(for: "S2"), "Ben", "other profiles are still suggested")

        // Confirming and relearning do not bring it back either.
        service.confirm("S1", inRecordID: third)
        XCTAssertEqual(service.state(of: "S1", inRecordID: third), .linked)
        service.relearn("S1", inRecordID: third)
        XCTAssertNil(names(second)?.displayName(for: "S1"))

        // A name the user types again is theirs, whatever was rejected.
        history.setSpeakerName("Anna", for: "S1", profileID: anna, inRecordID: second)
        XCTAssertEqual(service.state(of: "S1", inRecordID: second), .linked)
    }

    /// Issue #1558: a correction that splits a speaker's speech evenly keeps no
    /// voice for it; undoing the correction must bring that voice back.
    func testUndoingACorrectionRestoresTheVoicesItDropped() throws {
        let id = UUID()
        try SpeakerAudioWriter.writeAAC(
            samples: [Float](repeating: 0, count: 16_000),
            to: history.speakerAudioFileURL(forRecordID: id)
        )
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "First.", start: 0, end: 40, speakerID: "S1"),
            SpeakerTranscriptSegment(text: "Second one two three four.", start: 40, end: 70, speakerID: "S2"),
            SpeakerTranscriptSegment(text: "Third.", start: 70, end: 80, speakerID: "S3"),
        ])
        XCTAssertTrue(history.addSpeakerRecord(
            id: id,
            text: transcript.joinedText,
            title: "Meeting",
            source: .recorder,
            durationSeconds: 80,
            language: "en",
            engineUsed: "test",
            timedText: [],
            granularity: .segment,
            transcript: transcript
        ))
        let voices: [String: [Float]] = ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0, 0, 1]]
        service.recordVoices(voices, model: "model-a", of: transcript, recordID: id)
        let model = SpeakerWorkspaceModel(recordID: id, historyService: history, voices: service)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        // The second half of S2's turn goes to S3: neither keeps most of S2's speech.
        undoManager.beginUndoGrouping()
        model.split(at: 55, to: "S3", undoManager: undoManager)
        undoManager.endUndoGrouping()
        let split = try XCTUnwrap(model.transcript)
        XCTAssertEqual(split.segments.map(\.speakerID), ["S1", "S2", "S3", "S3"])
        XCTAssertNil(store.embeddings(forRecordID: id, revision: split.revision)["S2"])

        undoManager.undo()
        let restored = try XCTUnwrap(model.transcript)
        XCTAssertEqual(restored, transcript)
        XCTAssertTrue(store.hasCurrentEmbeddings(recordID: id, transcript: restored))
        XCTAssertEqual(store.embeddings(forRecordID: id, revision: restored.revision), voices)

        // Redo applies the correction again, as it was.
        undoManager.redo()
        XCTAssertEqual(model.transcript, split)
        XCTAssertTrue(store.hasCurrentEmbeddings(recordID: id, transcript: split))
        XCTAssertEqual(store.embeddings(forRecordID: id, revision: split.revision), ["S1": [1, 0, 0], "S3": [0, 0, 1]])
    }

    func testANewProfileIsSuggestedInEarlierRecordingsWithoutOverwritingNames() throws {
        let earlier = try addRecording()
        let named = try addRecording()
        history.setSpeakerName("Someone Else", for: "S1", inRecordID: named)
        let latest = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: latest)

        service.enroll("S1", inRecordID: latest)

        XCTAssertEqual(names(earlier)?.displayName(for: "S1"), "Anna")
        XCTAssertTrue(names(earlier)?.isSuggestion(for: "S1") == true)
        XCTAssertEqual(names(named)?.displayName(for: "S1"), "Someone Else")
    }

    func testRelearningReplacesTheVoiceAndEnrollingAKnownNameImprovesItsProfile() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)
        let profileID = try XCTUnwrap(store.profiles.first?.id)

        // The same name is enrolled again from another recording with a different voice sample.
        let second = try addRecording(["S1": [0, 0, 1], "S2": [0, 1, 0]])
        history.setSpeakerName("anna", for: "S1", inRecordID: second)
        service.enroll("S1", inRecordID: second)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profile(withID: profileID)?.enrolledSeconds, 80)
        XCTAssertEqual(store.profile(withID: profileID)?.embedding, [0.5, 0, 0.5])

        service.relearn("S1", inRecordID: second)
        XCTAssertEqual(store.profile(withID: profileID)?.embedding, [0, 0, 1])
        XCTAssertEqual(store.profile(withID: profileID)?.enrolledSeconds, 40)
    }

    func testAfterAModelChangeOldProfilesWaitForRelearningFromANewRecording() throws {
        let old = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: old)
        service.enroll("S1", inRecordID: old)
        let profileID = try XCTUnwrap(store.profiles.first?.id)

        // A new speaker model: the same voice gives other numbers.
        let new = try addRecording(["S1": [0, 1, 0], "S2": [0, 0, 1]], model: "model-b")
        XCTAssertNil(names(new)?.displayName(for: "S1"), "Anna's old profile isn't comparable")
        XCTAssertEqual(service.state(of: "S1", inRecordID: old), .linked, "the old recording can't relearn")
        history.setSpeakerName("Ben", for: "S2", inRecordID: old)
        XCTAssertEqual(service.state(of: "S2", inRecordID: old), .none, "an old voice can't start a profile")

        history.setSpeakerName("Anna", for: "S1", profileID: profileID, inRecordID: new)
        XCTAssertEqual(service.state(of: "S1", inRecordID: new), .outdated)
        service.relearn("S1", inRecordID: new)

        XCTAssertEqual(store.profile(withID: profileID)?.embeddingModel, "model-b")
        XCTAssertEqual(store.profile(withID: profileID)?.embedding, [0, 1, 0])
        XCTAssertEqual(service.state(of: "S1", inRecordID: new), .linked)
        let later = try addRecording(["S1": [0, 0.98, 0.05]], model: "model-b")
        XCTAssertEqual(names(later)?.displayName(for: "S1"), "Anna")
        XCTAssertEqual(service.state(of: "S1", inRecordID: later), .suggestion)
    }

    func testRenamingAProfileRenamesItsSpeakersAndDeletingKeepsNames() throws {
        let id = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: id)
        service.enroll("S1", inRecordID: id)
        let profileID = try XCTUnwrap(store.profiles.first?.id)

        service.renameProfile(profileID, to: " Anna Schmidt ")
        XCTAssertEqual(names(id)?.displayName(for: "S1"), "Anna Schmidt")
        XCTAssertEqual(names(id)?.profileID(for: "S1"), profileID)

        service.deleteProfile(profileID)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(names(id)?.displayName(for: "S1"), "Anna Schmidt")
    }

    func testVoicesAreRecognizedAndEnrolledWithoutAnAccount() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)

        let second = try addRecording()
        XCTAssertNotNil(names(second))
        XCTAssertNotNil(store.recordingEmbeddings[second])
        history.setSpeakerName("Ben", for: "S2", inRecordID: first)
        XCTAssertEqual(service.state(of: "S2", inRecordID: first), .canEnroll)
        service.enroll("S2", inRecordID: first)
        XCTAssertEqual(Set(store.profiles.map(\.name)), ["Anna", "Ben"])
        XCTAssertEqual(service.state(of: "S1", inRecordID: first), .linked)
    }

    func testEmbeddingsOfDeletedRecordingsAreRemoved() throws {
        let kept = try addRecording()
        let deleted = try addRecording()
        XCTAssertTrue(history.deleteRecord(withID: deleted))

        service.removeEmbeddingsOfDeletedRecordings()

        XCTAssertEqual(Set(store.recordingEmbeddings.keys), [kept])
    }

    func testDeletingRecordingsRemovesTheirEmbeddingsRightAway() throws {
        let kept = try addRecording()
        let deleted = try addRecording()
        let cleared = try addRecording()

        XCTAssertTrue(history.deleteRecord(withID: deleted))
        XCTAssertEqual(Set(store.recordingEmbeddings.keys), [kept, cleared])

        history.clearAll()
        XCTAssertTrue(store.recordingEmbeddings.isEmpty)
    }

    func testWorkspaceCorrectionsKeepVoicesAndRenamingUnlinksOrConfirms() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S2", inRecordID: first)
        service.enroll("S2", inRecordID: first)
        let profileID = try XCTUnwrap(store.profiles.first?.id)
        let model = SpeakerWorkspaceModel(recordID: first, historyService: history, voices: service)

        // Merging S1 into Anna's speaker numbers her S1; her name, link and voice follow.
        model.merge("S1", into: "S2", undoManager: nil)
        XCTAssertEqual(model.name(of: "S1"), "Anna")
        XCTAssertEqual(model.voiceState(of: "S1"), .linked)
        let revision = try XCTUnwrap(model.transcript?.revision)
        let merged = try XCTUnwrap(store.embeddings(forRecordID: first, revision: revision)["S1"])
        XCTAssertEqual(merged[0], 40.0 / 70, accuracy: 0.0001)
        XCTAssertEqual(merged[1], 30.0 / 70, accuracy: 0.0001)

        // Another name no longer belongs to the recognized voice.
        model.rename("S1", to: "Bea", undoManager: nil)
        XCTAssertNil(names(first)?.profileID(for: "S1"))

        // Typing the recognized name in a later recording confirms it.
        let second = try addRecording()
        XCTAssertEqual(service.state(of: "S2", inRecordID: second), .suggestion)
        let later = SpeakerWorkspaceModel(recordID: second, historyService: history, voices: service)
        later.rename("S2", to: "anna", undoManager: nil)
        XCTAssertEqual(later.voiceState(of: "S2"), .linked)
        XCTAssertEqual(store.profile(withID: profileID)?.enrolledSeconds, 60)
    }
}

/// Exercises the production router and service against disposable on-disk stores.
@MainActor
final class SpeakerProfileAPITests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!
    private var store: VoiceProfileStore!
    private var service: SpeakerVoiceProfileService!
    private var router: APIRouter!
    private var failHistorySave = false

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        rebuildServices()
    }

    override func tearDown() async throws {
        router = nil
        service = nil
        store = nil
        history = nil
        TestSupport.remove(directory)
    }

    private func rebuildServices() {
        router = nil
        service = nil
        history = nil
        store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("voices"))
        history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in }, speakerNameWriter: { [unowned self] context in
            if self.failHistorySave { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        service = SpeakerVoiceProfileService(store: store, historyService: history)
        router = APIRouter(tokenProvider: { "test-token" })
        APISpeakerProfiles.register(on: router, service: service)
    }

    @discardableResult
    private func recording(embedding: [Float] = [1, 0, 0], seconds: Double = 40, model: String = "test-model") throws -> (UUID, UUID) {
        let id = UUID()
        try SpeakerAudioWriter.writeAAC(samples: [Float](repeating: 0, count: 16_000), to: history.speakerAudioFileURL(forRecordID: id))
        let transcript = SpeakerTranscript(source: .localDiarizer, segments: [
            SpeakerTranscriptSegment(text: "Test speaker.", start: 0, end: seconds, speakerID: "S1")
        ])
        XCTAssertTrue(history.addSpeakerRecord(
            id: id, text: transcript.joinedText, title: "API fixture", source: .recorder,
            durationSeconds: seconds, language: "en", engineUsed: "fixture", timedText: [], granularity: .segment,
            transcript: transcript
        ))
        service.recordVoices(["S1": embedding], model: model, of: transcript, recordID: id)
        return (id, transcript.revision)
    }

    private func request(_ action: String, _ record: (UUID, UUID), extra: [String: Any] = [:], token: String? = "test-token") throws -> HTTPRequest {
        var body: [String: Any] = ["history_id": record.0.uuidString, "transcript_revision": record.1.uuidString,
                                   "transcript_version": history.record(withID: record.0)?.speakerTranscript?.automationVersion ?? "missing",
                                   "speaker_id": "S1"]
        body.merge(extra) { _, new in new }
        var headers = ["content-type": "application/json"]
        if let token { headers["authorization"] = "Bearer " + token }
        return HTTPRequest(method: action == "name" ? "PUT" : "POST", path: "/v1/history/speakers/" + action,
                           queryParams: [:], headers: headers, body: try JSONSerialization.data(withJSONObject: body))
    }

    private func call(_ action: String, _ record: (UUID, UUID), extra: [String: Any] = [:], token: String? = "test-token") async throws -> HTTPResponse {
        await router.route(try request(action, record, extra: extra, token: token))
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func assertStatus(_ response: HTTPResponse, _ status: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.status, status, String(data: response.body, encoding: .utf8) ?? "", file: file, line: line)
    }

    func testTokenIsRequiredEvenWhenLegacyAuthenticationIsDisabled() async throws {
        let record = try recording()
        for action in ["name", "enroll", "confirm"] {
            assertStatus(try await call(action, record, token: nil), 401)
            assertStatus(try await call(action, record, token: "wrong"), 401)
            let trusted = await router.routeTrusted(try request(action, record))
            assertStatus(trusted, 403)
            XCTAssertFalse(RemoteLinkServer.allowedRoutes.contains("\(action == "name" ? "PUT" : "POST") /v1/history/speakers/\(action)"))
        }
        router.register("GET", "/v1/history") { _ in .json(["ok": true]) }
        let legacy = await router.route(HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()))
        assertStatus(legacy, 200)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testNamingAndLearningRoundTripAcrossRestartAndLaterRecording() async throws {
        let first = try recording()
        assertStatus(try await call("name", first, extra: ["name": "Anna"]), 200)
        XCTAssertTrue(store.profiles.isEmpty)
        let enrolled = try await call("enroll", first)
        assertStatus(enrolled, 200)
        let profileID = try XCTUnwrap(try json(enrolled)["profile_id"] as? String)
        XCTAssertEqual(try json(enrolled)["voice_state"] as? String, "linked")
        XCTAssertEqual(try json(enrolled)["already_learned"] as? Bool, false)
        rebuildServices()
        let repeated = try await call("enroll", first)
        assertStatus(repeated, 200)
        XCTAssertEqual(try json(repeated)["already_learned"] as? Bool, true)
        XCTAssertEqual(try json(repeated)["profile_id"] as? String, profileID)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)

        let second = try recording(embedding: [0.98, 0.05, 0], seconds: 30)
        let suggested = try XCTUnwrap(service.automationState(recordID: second.0, speakerID: "S1"))
        XCTAssertEqual(suggested.suggested_name, "Anna")
        XCTAssertNil(suggested.name)
        XCTAssertEqual(suggested.profile_id?.uuidString, profileID)
        assertStatus(try await call("enroll", second), 409)
        assertStatus(try await call("confirm", second, extra: ["profile_id": UUID().uuidString]), 409)
        assertStatus(try await call("confirm", second, extra: ["profile_id": profileID]), 200)
        rebuildServices()
        let confirmedAgain = try await call("confirm", second, extra: ["profile_id": profileID])
        assertStatus(confirmedAgain, 200)
        XCTAssertEqual(try json(confirmedAgain)["already_learned"] as? Bool, true)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 70)
    }

    func testRetryRepairsHistoryAfterVoiceCommitWithoutLearningAgain() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        failHistorySave = true
        assertStatus(try await call("enroll", record), 500)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
        XCTAssertNil(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"))
        failHistorySave = false
        rebuildServices()
        let retry = try await call("enroll", record)
        assertStatus(retry, 200)
        XCTAssertEqual(try json(retry)["already_learned"] as? Bool, true)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
        XCTAssertNotNil(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"))
    }

    func testProfileWriteFailureDoesNotPublishOrConfirmAndRetryWorks() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        let file = directory.appendingPathComponent("voices/voice-profiles.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        assertStatus(try await call("enroll", record), 500)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.learnedProfile(recordID: record.0, revision: record.1, speakerID: "S1"))
        XCTAssertNil(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"))
        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        assertStatus(try await call("enroll", record), 200)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNameSaveFailureRestoresPreviousValue() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        failHistorySave = true
        assertStatus(try await call("name", record, extra: ["name": "Ben"]), 500)
        XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.displayName(for: "S1"), "Anna")
        failHistorySave = false
        rebuildServices()
        XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.displayName(for: "S1"), "Anna")
    }

    func testValidationLeavesStoresUntouched() async throws {
        let record = try recording(seconds: 10)
        assertStatus(try await call("name", record, extra: ["name": "  "]), 400)
        assertStatus(try await call("name", record, extra: ["name": "A\u{0}B"]), 400)
        assertStatus(try await call("name", record, extra: ["name": String(repeating: "a", count: 101)]), 400)
        assertStatus(try await call("name", record, extra: ["name": "Anna", "unknown": true]), 400)
        assertStatus(try await call("name", (UUID(), record.1), extra: ["name": "Anna"]), 404)
        assertStatus(try await call("name", (record.0, UUID()), extra: ["name": "Anna"]), 409)
        assertStatus(try await call("name", record, extra: ["name": "Anna", "speaker_id": "S99"]), 404)
        assertStatus(try await call("confirm", record), 400)
        assertStatus(try await call("enroll", record), 422)
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", record), 422)
        XCTAssertTrue(store.profiles.isEmpty)
        history.record(withID: record.0)?.speakerTranscriptState = .pending
        assertStatus(try await call("name", record, extra: ["name": "Ben"]), 409)
    }

    func testSameNamesCreateSeparateProfilesUnlessIDIsExplicit() async throws {
        let first = try recording()
        assertStatus(try await call("name", first, extra: ["name": "Alex"]), 200)
        assertStatus(try await call("enroll", first), 200)
        let id = try XCTUnwrap(store.profiles.first?.id)
        let second = try recording(embedding: [0, 1, 0])
        assertStatus(try await call("name", second, extra: ["name": "Alex"]), 200)
        assertStatus(try await call("enroll", second), 409)
        assertStatus(try await call("enroll", second, extra: ["create_profile": true]), 200)
        XCTAssertEqual(store.profiles.count, 2)
        let third = try recording(embedding: [0, 0, 1])
        assertStatus(try await call("name", third, extra: ["name": "Alex"]), 200)
        service.enroll("S1", inRecordID: third.0)
        XCTAssertEqual(store.profile(withID: id)?.enrolledSeconds, 40)
        XCTAssertNil(history.record(withID: third.0)?.speakerNames?.profileID(for: "S1"))
        assertStatus(try await call("enroll", third, extra: ["profile_id": id.uuidString]), 200)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.profile(withID: id)?.enrolledSeconds, 80)
        assertStatus(try await call("enroll", second, extra: ["profile_id": id.uuidString]), 409)
    }

    func testNamingASuggestionDoesNotLearnAndDeletedProfileCannotBeResurrectedByRetry() async throws {
        let first = try recording()
        assertStatus(try await call("name", first, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", first), 200)
        let id = try XCTUnwrap(store.profiles.first?.id)
        let second = try recording()
        assertStatus(try await call("name", second, extra: ["name": "Anna"]), 200)
        XCTAssertEqual(store.profile(withID: id)?.enrolledSeconds, 40)
        XCTAssertNil(history.record(withID: second.0)?.speakerNames?.profileID(for: "S1"))
        assertStatus(try await call("confirm", second, extra: ["profile_id": id.uuidString]), 409)
        service.deleteProfile(id)
        rebuildServices()
        assertStatus(try await call("enroll", first), 409)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testModelMismatchAndMissingEmbeddingCannotTrain() async throws {
        let first = try recording()
        assertStatus(try await call("name", first, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", first), 200)
        let id = try XCTUnwrap(store.profiles.first?.id)
        let second = try recording(model: "other-model")
        assertStatus(try await call("name", second, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", second, extra: ["profile_id": id.uuidString]), 409)
        store.removeEmbeddings(forRecordIDs: [second.0])
        assertStatus(try await call("enroll", second, extra: ["profile_id": id.uuidString]), 422)
        XCTAssertEqual(store.profile(withID: id)?.enrolledSeconds, 40)
    }
    func testConcurrentRetriesAndReceiptAfterModelChange() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        let request = try request("enroll", record)
        let router = self.router!
        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<12 { group.addTask { await router.route(request).status } }
            var statuses: [Int] = []
            for await status in group { statuses.append(status) }
            return statuses
        }
        XCTAssertEqual(statuses, Array(repeating: 200, count: 12))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
        try recording(model: "new-model")
        store.removeEmbeddings(forRecordIDs: [record.0])
        rebuildServices()
        assertStatus(try await call("enroll", record), 200)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
    }

    func testRealHTTPConnectionCanNameEnrollAndRetry() async throws {
        let record = try recording()
        let server = HTTPServer(router: router)
        let ready = expectation(description: "Loopback API listening")
        server.onStateChange = { if $0 { ready.fulfill() } }
        let port = UInt16.random(in: 49_152...65_535)
        try server.start(port: port)
        defer { server.stopAndCancelActiveRequests() }
        await fulfillment(of: [ready], timeout: 5)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for action in ["name", "enroll", "enroll"] {
            let source = try request(action, record, extra: action == "name" ? ["name": "Anna"] : [:])
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(source.path)")!)
            request.httpMethod = source.method
            request.httpBody = source.body
            request.allHTTPHeaderFields = source.headers
            request.timeoutInterval = 5
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        }
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.enrolledSeconds, 40)
    }

    func testHistoryExposesRevisionSuggestionProfileAndLearningStateWithoutEmbeddings() async throws {
        let first = try recording()
        assertStatus(try await call("name", first, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", first), 200)
        let second = try recording()
        let request = HTTPRequest(method: "GET", path: "/v1/history", queryParams: ["include": "speaker_segments"], headers: [:], body: Data())
        let response = APIHandlers.historyResponse(request, historyService: history, speakerVoices: service)
        let entries = try XCTUnwrap(try json(response)["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first { $0["id"] as? String == second.0.uuidString })
        XCTAssertEqual(entry["transcript_revision"] as? String, second.1.uuidString)
        XCTAssertEqual(entry["transcript_version"] as? String, history.record(withID: second.0)?.speakerTranscript?.automationVersion)
        let speaker = try XCTUnwrap((entry["speakers"] as? [[String: Any]])?.first)
        XCTAssertEqual(speaker["name"] as? String, "Speaker 1")
        XCTAssertEqual(speaker["suggested_name"] as? String, "Anna")
        XCTAssertEqual(speaker["voice_state"] as? String, "suggestion")
        XCTAssertEqual(speaker["profile_id"] as? String, store.profiles.first?.id.uuidString)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("embedding"))
    }

    func testExplicitWorkspaceReassignmentAndReEnrollmentRemainAvailable() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        service.enroll("S1", inRecordID: record.0)
        XCTAssertEqual(store.profiles.count, 1)
        history.setSpeakerName("Ben", for: "S1", inRecordID: record.0)
        service.enroll("S1", inRecordID: record.0)
        XCTAssertEqual(store.profiles.count, 2)
        let ben = try XCTUnwrap(store.profile(named: "Ben"))
        XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"), ben.id)
        service.deleteProfile(ben.id)
        service.enroll("S1", inRecordID: record.0)
        let newBen = try XCTUnwrap(store.profile(named: "Ben"))
        XCTAssertNotEqual(newBen.id, ben.id)
        XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"), newBen.id)
    }

    private func multipleSpeakers() throws -> (UUID, UUID) {
        let record = try recording()
        let transcript = SpeakerTranscript(revision: record.1, source: .localDiarizer, segments: (0..<4).map {
            SpeakerTranscriptSegment(text: "Speaker sample with several words for splitting.",
                                     start: Double($0 * 30), end: Double(($0 + 1) * 30), speakerID: "S\($0 + 1)")
        })
        history.storeSpeakerTranscript(transcript, forRecordID: record.0)
        service.recordVoices(["S1": [1, 0, 0], "S2": [0.99, 0.01, 0], "S3": [0, 1, 0], "S4": [0, 0, 1]],
                             model: "test-model", of: transcript, recordID: record.0)
        return record
    }

    func testCorrectionsRejectOldRequestsAndReceiptsFollowRenumberedSpeakers() async throws {
        let record = try multipleSpeakers()
        for (speaker, name) in [("S3", "Bob"), ("S4", "Carol")] {
            assertStatus(try await call("name", record, extra: ["speaker_id": speaker, "name": name]), 200)
            assertStatus(try await call("enroll", record, extra: ["speaker_id": speaker]), 200)
        }
        let bob = try XCTUnwrap(store.profile(named: "Bob"))
        let carol = try XCTUnwrap(store.profile(named: "Carol"))
        let oldRequests = try [request("name", record, extra: ["speaker_id": "S3", "name": "Wrong"]),
                               request("enroll", record, extra: ["speaker_id": "S3"]),
                               request("confirm", record, extra: ["speaker_id": "S3", "profile_id": bob.id.uuidString])]
        let workspace = SpeakerWorkspaceModel(recordID: record.0, historyService: history, voices: service)
        workspace.merge("S2", into: "S1", undoManager: nil)
        XCTAssertEqual(history.record(withID: record.0)?.speakerTranscript?.revision, record.1)
        for request in oldRequests { assertStatus(await router.route(request), 409) }
        rebuildServices()
        for (speaker, profile) in [("S2", bob), ("S3", carol)] {
            let reply = try await call("enroll", record, extra: ["speaker_id": speaker, "profile_id": profile.id.uuidString])
            assertStatus(reply, 200)
            XCTAssertEqual(try json(reply)["already_learned"] as? Bool, true)
            XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 30)
        }
    }

    func testAssignAndSplitInvalidateTranscriptVersion() async throws {
        let record = try multipleSpeakers()
        let workspace = SpeakerWorkspaceModel(recordID: record.0, historyService: history, voices: service)
        let beforeAssign = try request("name", record, extra: ["name": "Old"])
        workspace.assign(turns: [1], to: "S1", undoManager: nil)
        assertStatus(await router.route(beforeAssign), 409)
        let beforeSplit = try request("name", record, extra: ["name": "Old"])
        workspace.split(at: 10, to: nil, undoManager: nil)
        assertStatus(await router.route(beforeSplit), 409)
        assertStatus(try await call("name", record, extra: ["name": "Current"]), 200)
    }

    func testPartiallyLearnedMergeRequiresExplicitRelearningAndThenRetriesAreSafe() async throws {
        let record = try multipleSpeakers()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", record), 200)
        let profile = try XCTUnwrap(store.profile(named: "Anna"))
        let workspace = SpeakerWorkspaceModel(recordID: record.0, historyService: history, voices: service)
        workspace.merge("S2", into: "S1", undoManager: nil)
        assertStatus(try await call("enroll", record), 409)
        XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 30)
        service.relearn("S1", inRecordID: record.0)
        XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 60)
        rebuildServices()
        let retry = try await call("enroll", record)
        assertStatus(retry, 200)
        XCTAssertEqual(try json(retry)["already_learned"] as? Bool, true)
        XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 60)
    }

    func testFailedCorrectionPersistenceCannotUseWrongSpeakerEmbeddingsAfterRestart() async throws {
        let record = try multipleSpeakers()
        assertStatus(try await call("name", record, extra: ["speaker_id": "S3", "name": "Bob"]), 200)
        assertStatus(try await call("enroll", record, extra: ["speaker_id": "S3"]), 200)
        let file = directory.appendingPathComponent("voices/voice-profiles.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let workspace = SpeakerWorkspaceModel(recordID: record.0, historyService: history, voices: service)
        workspace.merge("S2", into: "S1", undoManager: nil)
        XCTAssertEqual(history.record(withID: record.0)?.speakerTranscript?.speakerIDs.count, 3)
        assertStatus(try await call("enroll", record, extra: ["speaker_id": "S2"]), 409)
        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        rebuildServices()
        let retry = try await call("enroll", record, extra: ["speaker_id": "S2"])
        assertStatus(retry, 409)
        XCTAssertEqual((try json(retry)["error"] as? [String: Any])?["code"] as? String, "stale_voice_samples")
        XCTAssertEqual(store.profile(named: "Bob")?.enrolledSeconds, 30)
    }

    func testLegacyLinkAndWorkspaceNameRoundTripsDoNotLearnAgain() async throws {
        let record = try recording()
        let profile = store.enroll(name: "Anna", embedding: [1, 0, 0], model: "test-model", seconds: 40)
        history.setSpeakerName("Anna", for: "S1", profileID: profile.id, inRecordID: record.0)
        assertStatus(try await call("name", record, extra: ["name": "ANNA"]), 200)
        XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.profileID(for: "S1"), profile.id)
        assertStatus(try await call("name", record, extra: ["name": "Ben"]), 200)
        service.enroll("S1", inRecordID: record.0)
        XCTAssertEqual(store.profiles.count, 2)
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        service.enroll("S1", inRecordID: record.0)
        rebuildServices()
        let retry = try await call("enroll", record)
        assertStatus(retry, 200)
        XCTAssertEqual(try json(retry)["already_learned"] as? Bool, true)
        XCTAssertEqual(store.profile(withID: profile.id)?.enrolledSeconds, 40)
    }

    func testUnicodeNamesAndExplicitDuplicateChoice() async throws {
        let record = try recording()
        for name in ["Name\u{200C}Name", "Name\u{200D}Name"] {
            assertStatus(try await call("name", record, extra: ["name": name]), 200)
            XCTAssertEqual(history.record(withID: record.0)?.speakerNames?.displayName(for: "S1"), name)
        }
        assertStatus(try await call("name", record, extra: ["name": "A\nB"]), 400)
        assertStatus(try await call("name", record, extra: ["name": "Alex"]), 200)
        let existing = store.enroll(name: "Alex", embedding: [0, 1, 0], model: "test-model", seconds: 40)
        let conflict = try await call("enroll", record)
        assertStatus(conflict, 409)
        XCTAssertEqual((try json(conflict)["error"] as? [String: Any])?["profile_ids"] as? [String], [existing.id.uuidString])
        XCTAssertEqual(store.profiles.count, 1)
        assertStatus(try await call("enroll", record, extra: ["create_profile": true, "profile_id": existing.id.uuidString]), 400)
        assertStatus(try await call("enroll", record, extra: ["profile_id": existing.id.uuidString]), 200)
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testDeletingHistoryPurgesReceiptsButDeletingProfileRetainsTombstone() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", record), 200)
        service.deleteProfile(try XCTUnwrap(store.profiles.first?.id))
        XCTAssertTrue(store.storedRecordIDs.contains(record.0))
        XCTAssertTrue(history.deleteRecord(withID: record.0))
        XCTAssertFalse(store.storedRecordIDs.contains(record.0))
        rebuildServices()
        XCTAssertFalse(store.storedRecordIDs.contains(record.0))
        let bytes = try Data(contentsOf: directory.appendingPathComponent("voices/voice-profiles.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(record.0.uuidString))
    }

    func testVersionIsRequiredAndHistoryStateReflectsPremium() async throws {
        let record = try recording()
        for action in ["name", "enroll", "confirm"] {
            let original = try request(action, record, extra: ["name": "Anna"])
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: original.body) as? [String: Any])
            body.removeValue(forKey: "transcript_version")
            if action != "name" { body.removeValue(forKey: "name") }
            if action == "confirm" { body["profile_id"] = UUID().uuidString }
            let missing = HTTPRequest(method: original.method, path: original.path, queryParams: [:],
                                      headers: original.headers, body: try JSONSerialization.data(withJSONObject: body))
            assertStatus(await router.route(missing), 400)
        }
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        XCTAssertEqual(service.automationState(recordID: record.0, speakerID: "S1")?.voice_state, "canEnroll")
    }

    func testStartupCleanupAlsoPurgesReceiptsWithoutEmbeddings() async throws {
        let record = try recording()
        assertStatus(try await call("name", record, extra: ["name": "Anna"]), 200)
        assertStatus(try await call("enroll", record), 200)
        let file = directory.appendingPathComponent("voices/voice-profiles.json")
        let bytes = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["recordings"] = [] // UUID-keyed Codable dictionaries use alternating arrays.
        history.onRecordsDeleted = nil
        XCTAssertTrue(history.deleteRecord(withID: record.0))
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        rebuildServices()
        XCTAssertTrue(store.recordingEmbeddings.isEmpty)
        XCTAssertTrue(store.storedRecordIDs.contains(record.0))
        service.removeEmbeddingsOfDeletedRecordings()
        rebuildServices()
        XCTAssertFalse(store.storedRecordIDs.contains(record.0))
        XCTAssertEqual(store.profiles.count, 1)
    }

}
