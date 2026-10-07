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
    private var hasPremium = true

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        history = HistoryService(appSupportDirectory: directory)
        store = VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles"))
        hasPremium = true
        service = SpeakerVoiceProfileService(
            store: store,
            historyService: history,
            premiumAccess: { [unowned self] in self.hasPremium }
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

    func testWithoutPremiumVoicesAreNeitherStoredRecognizedNorEnrolled() throws {
        let first = try addRecording()
        history.setSpeakerName("Anna", for: "S1", inRecordID: first)
        service.enroll("S1", inRecordID: first)

        hasPremium = false
        let second = try addRecording()
        XCTAssertNil(names(second))
        XCTAssertTrue(store.recordingEmbeddings[second] == nil)
        history.setSpeakerName("Ben", for: "S2", inRecordID: first)
        XCTAssertEqual(service.state(of: "S2", inRecordID: first), .none)
        service.enroll("S2", inRecordID: first)
        XCTAssertEqual(store.profiles.map(\.name), ["Anna"], "profiles are kept without Premium")
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
