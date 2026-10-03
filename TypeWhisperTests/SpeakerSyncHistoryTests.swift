import XCTest
@testable import TypeWhisper

@MainActor
final class SpeakerSyncHistoryTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var history: HistoryService!
    private let recordID = UUID(uuidString: "83600000-0000-4000-8000-0000000000B1")!
    private let epoch = Date(timeIntervalSince1970: 0)

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory()
        suiteName = "SpeakerSyncHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences)
    }

    override func tearDown() async throws {
        history = nil
        defaults.removePersistentDomain(forName: suiteName)
        TestSupport.remove(directory)
    }

    private var transcript: SpeakerTranscript {
        SpeakerTranscript(
            revision: UUID(uuidString: "C1D9A3B2-5E6F-4A7B-8C9D-0E1F2A3B4C5D")!,
            source: .localDiarizer,
            segments: [
                SpeakerTranscriptSegment(text: "Good morning.", start: 0, end: 30, speakerID: "S1"),
                SpeakerTranscriptSegment(text: "Morning.", start: 30, end: 60, speakerID: "S2"),
            ]
        )
    }

    /// A recording that waits for speaker detection.
    private func addPendingRecording() throws {
        try SpeakerAudioWriter.writeAAC(
            samples: [Float](repeating: 0, count: 16_000),
            to: history.speakerAudioFileURL(forRecordID: recordID)
        )
        XCTAssertTrue(history.addSpeakerRecord(
            id: recordID,
            text: "Good morning. Morning.",
            title: "Meeting",
            source: .recorder,
            durationSeconds: 60,
            language: "en",
            engineUsed: "test",
            timedText: [TimedTextEntry(text: "Good morning.", start: 0, end: 30, utf16Location: 0, utf16Length: 13)],
            granularity: .segment
        ))
    }

    private var exported: UserDataSyncHistoryRecord? {
        history.userDataSyncHistoryRecords().first { $0.content.recordID == recordID }
    }

    private var record: TranscriptionRecord? { history.record(withID: recordID) }

    func testTranscriptAndNamesAreExportedOnceTheyExistAndChange() throws {
        try addPendingRecording()
        XCTAssertNotNil(exported)
        XCTAssertNil(exported?.transcript, "nothing to sync while detection is pending")
        XCTAssertNil(exported?.speakers)

        XCTAssertTrue(history.storeSpeakerTranscript(transcript, forRecordID: recordID))
        let stored = try XCTUnwrap(exported?.transcript)
        XCTAssertEqual(stored.revision, transcript.revision)
        XCTAssertEqual(stored.speakerTranscript, transcript)
        XCTAssertEqual(stored.updatedAt, record?.speakerTranscriptUpdatedAt)
        XCTAssertNil(exported?.speakers, "no names were ever given")

        // A suggestion from a voice profile stays on this device.
        history.setSpeakerName("Guess", for: "S2", profileID: UUID(), isSuggestion: true, inRecordID: recordID)
        XCTAssertEqual(record?.speakerNamesUpdatedAt, epoch)
        XCTAssertNil(exported?.speakers)

        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        let names = try XCTUnwrap(exported?.speakers)
        XCTAssertEqual(names.transcriptRevision, transcript.revision)
        XCTAssertEqual(names.names, [.init(speakerID: "S1", displayName: "Anna", profileID: nil, updatedAt: record?.speakerNamesUpdatedAt)])
        XCTAssertEqual(names.updatedAt, record?.speakerNamesUpdatedAt)
        XCTAssertEqual(exported?.transcript?.updatedAt, stored.updatedAt, "renaming does not touch the transcript")

        // Clearing the last name is exported as an empty list and a dated removal.
        history.setSpeakerName("", for: "S1", inRecordID: recordID)
        XCTAssertEqual(exported?.speakers?.names, [])
        XCTAssertEqual(exported?.speakers?.cleared.map(\.speakerID), ["S1"])
        XCTAssertEqual(exported?.speakers?.cleared.first?.updatedAt, record?.speakerNamesUpdatedAt)
    }

    func testCorrectionsBumpOnlyWhatChanged() throws {
        try addPendingRecording()
        history.storeSpeakerTranscript(transcript, forRecordID: recordID)
        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        let transcriptStamp = try XCTUnwrap(record?.speakerTranscriptUpdatedAt)
        let namesStamp = try XCTUnwrap(record?.speakerNamesUpdatedAt)
        let contentStamp = try XCTUnwrap(record?.contentUpdatedAt)

        // Storing the same transcript and names again changes nothing.
        XCTAssertTrue(history.updateSpeakerTranscript(transcript, names: record?.speakerNames, forRecordID: recordID))
        XCTAssertEqual(record?.speakerTranscriptUpdatedAt, transcriptStamp)
        XCTAssertEqual(record?.speakerNamesUpdatedAt, namesStamp)

        // Giving Anna's turn to S2 numbers the remaining speaker S1 and drops Anna's name.
        let merged = transcript.merging("S1", into: "S2")
        XCTAssertTrue(history.updateSpeakerTranscript(merged, names: record?.speakerNames, forRecordID: recordID))
        XCTAssertGreaterThan(try XCTUnwrap(record?.speakerTranscriptUpdatedAt), transcriptStamp)
        XCTAssertGreaterThan(try XCTUnwrap(record?.speakerNamesUpdatedAt), namesStamp)
        XCTAssertEqual(record?.contentUpdatedAt, contentStamp)
        XCTAssertEqual(exported?.transcript?.segments.map(\.speakerID), ["S1", "S1"])
        XCTAssertEqual(exported?.speakers?.names, [])
    }

    func testRemoteTranscriptAndNamesAreAppliedInEitherOrder() throws {
        let remoteDate = Date(timeIntervalSince1970: 1_800_000_000)
        let wireTranscript = UserDataSyncHistoryTranscriptV1(recordID: recordID, updatedAt: remoteDate, transcript: transcript)
        var table = SpeakerNameTable(transcriptRevision: transcript.revision)
        table.setName("Anna", for: "S1", profileID: UUID())
        let wireNames = UserDataSyncHistorySpeakersV1(
            recordID: recordID,
            updatedAt: remoteDate.addingTimeInterval(5),
            transcriptRevision: transcript.revision,
            table: table
        )

        // The names arrive first and wait for their transcript.
        try history.applyUserDataSyncMutations([.upsertHistorySpeakers(wireNames)])
        XCTAssertNil(record?.speakerNames)
        XCTAssertNil(record?.speakerTranscriptState)

        try history.applyUserDataSyncMutations([.upsertHistoryTranscript(wireTranscript)])
        XCTAssertEqual(record?.speakerTranscriptState, .ready)
        XCTAssertEqual(record?.speakerTranscript, transcript)
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S1"), "Anna")
        // Applying does not stamp the record with the local time.
        XCTAssertEqual(record?.speakerTranscriptUpdatedAt, remoteDate)
        XCTAssertEqual(record?.speakerNamesUpdatedAt, remoteDate.addingTimeInterval(5))
        XCTAssertEqual(exported?.transcript, wireTranscript)
        // Names without their own date take the payload's date.
        XCTAssertEqual(exported?.speakers?.updatedAt, wireNames.updatedAt)
        XCTAssertEqual(exported?.speakers?.names.map(\.displayName), ["Anna"])
        XCTAssertEqual(exported?.speakers?.names.first?.updatedAt, wireNames.updatedAt)

        // The synced profile link belongs to the other device.
        let voices = SpeakerVoiceProfileService(
            store: VoiceProfileStore(directoryURL: directory.appendingPathComponent("VoiceProfiles")),
            historyService: history,
            premiumAccess: { true }
        )
        XCTAssertEqual(voices.state(of: "S1", inRecordID: recordID), .none)
    }

    func testOlderRemoteDataLosesAndLocalSuggestionsSurviveRemoteNames() throws {
        try addPendingRecording()
        history.storeSpeakerTranscript(transcript, forRecordID: recordID)
        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        let profileID = UUID()
        history.setSpeakerName("Guess", for: "S2", profileID: profileID, isSuggestion: true, inRecordID: recordID)
        let namesStamp = try XCTUnwrap(record?.speakerNamesUpdatedAt)

        var older = SpeakerNameTable(transcriptRevision: transcript.revision)
        older.setName("Old", for: "S1")
        try history.applyUserDataSyncMutations([.upsertHistorySpeakers(UserDataSyncHistorySpeakersV1(
            recordID: recordID,
            updatedAt: namesStamp.addingTimeInterval(-60),
            transcriptRevision: transcript.revision,
            table: older
        ))])
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S1"), "Anna")

        var newer = SpeakerNameTable(transcriptRevision: transcript.revision)
        newer.setName("Anna Schmidt", for: "S1")
        try history.applyUserDataSyncMutations([.upsertHistorySpeakers(UserDataSyncHistorySpeakersV1(
            recordID: recordID,
            updatedAt: namesStamp.addingTimeInterval(60),
            transcriptRevision: transcript.revision,
            table: newer
        ))])
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S1"), "Anna Schmidt")
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S2"), "Guess")
        XCTAssertTrue(record?.speakerNames?.isSuggestion(for: "S2") == true)
        XCTAssertEqual(record?.speakerNames?.profileID(for: "S2"), profileID)
        // The kept suggestion is still not exported.
        XCTAssertEqual(exported?.speakers?.names.map(\.displayName), ["Anna Schmidt"])

        // A transcript from a new detection run elsewhere hides names of the old revision.
        let rerun = SpeakerTranscript(source: .localDiarizer, segments: transcript.segments)
        try history.applyUserDataSyncMutations([.upsertHistoryTranscript(UserDataSyncHistoryTranscriptV1(
            recordID: recordID,
            updatedAt: Date().addingTimeInterval(120),
            transcript: rerun
        ))])
        XCTAssertEqual(record?.speakerTranscript?.revision, rerun.revision)
        XCTAssertNil(record?.speakerNames)
        XCTAssertEqual(exported?.speakers?.names, [])
    }

    /// Another device with the same record, kept in its own folder.
    private func makeOtherDevice() throws -> (HistoryService, URL, UserDefaults, String) {
        let otherDirectory = try TestSupport.makeTemporaryDirectory()
        let otherSuite = "SpeakerSyncHistoryTests-other-\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        let preferences = HistorySyncPreferences(defaults: otherDefaults)
        preferences.isEnabled = true
        let other = HistoryService(appSupportDirectory: otherDirectory, historySyncPreferences: preferences)
        return (other, otherDirectory, otherDefaults, otherSuite)
    }

    func testDevicesNamingDifferentSpeakersAtOnceBothKeepBothNames() throws {
        try addPendingRecording()
        history.storeSpeakerTranscript(transcript, forRecordID: recordID)
        let wireTranscript = try XCTUnwrap(exported?.transcript)
        let (other, otherDirectory, otherDefaults, otherSuite) = try makeOtherDevice()
        defer {
            otherDefaults.removePersistentDomain(forName: otherSuite)
            TestSupport.remove(otherDirectory)
        }
        try other.applyUserDataSyncMutations([.upsertHistoryTranscript(wireTranscript)])

        // This Mac names S1; the other device names S2 a minute later, before either syncs.
        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        var otherNames = SpeakerNameTable(transcriptRevision: transcript.revision)
        otherNames.setName("Ben", for: "S2")
        let later = try XCTUnwrap(record?.speakerNamesUpdatedAt).addingTimeInterval(60)
        let fromOther = UserDataSyncHistorySpeakersV1(
            recordID: recordID,
            updatedAt: later,
            transcriptRevision: transcript.revision,
            table: otherNames
        )
        try other.applyUserDataSyncMutations([.upsertHistorySpeakers(fromOther)])

        // The newer table from the other device does not drop Anna here, and
        // this Mac publishes a newer table because the other device lacks her.
        try history.applyUserDataSyncMutations([.upsertHistorySpeakers(fromOther)])
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S1"), "Anna")
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S2"), "Ben")
        let republished = try XCTUnwrap(exported?.speakers)
        XCTAssertGreaterThan(republished.updatedAt, later)
        XCTAssertEqual(republished.names.map(\.displayName), ["Anna", "Ben"])

        // The other device takes both names and has nothing new to publish.
        try other.applyUserDataSyncMutations([.upsertHistorySpeakers(republished)])
        let otherRecord = try XCTUnwrap(other.record(withID: recordID))
        XCTAssertEqual(otherRecord.speakerNames?.displayName(for: "S1"), "Anna")
        XCTAssertEqual(otherRecord.speakerNames?.displayName(for: "S2"), "Ben")
        XCTAssertEqual(otherRecord.speakerNamesUpdatedAt, republished.updatedAt)
    }

    func testANewerRemovalWinsAndAnOlderOneDoesNot() throws {
        try addPendingRecording()
        history.storeSpeakerTranscript(transcript, forRecordID: recordID)
        history.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        let named = try XCTUnwrap(record?.speakerNamesUpdatedAt)

        func removal(of speakerID: String, at date: Date) -> UserDataSyncMutation {
            var table = SpeakerNameTable(transcriptRevision: transcript.revision)
            table.setName("Gone", for: speakerID)
            let stamped = SpeakerNameTable(transcriptRevision: transcript.revision)
                .stamped(against: table.stamped(against: nil, at: date), at: date)
            return .upsertHistorySpeakers(UserDataSyncHistorySpeakersV1(
                recordID: recordID,
                updatedAt: date,
                transcriptRevision: transcript.revision,
                table: stamped
            ))
        }

        try history.applyUserDataSyncMutations([removal(of: "S1", at: named.addingTimeInterval(-60))])
        XCTAssertEqual(record?.speakerNames?.displayName(for: "S1"), "Anna", "an older removal loses")

        try history.applyUserDataSyncMutations([removal(of: "S1", at: named.addingTimeInterval(60))])
        XCTAssertNil(record?.speakerNames?.displayName(for: "S1"), "a newer removal wins")
        XCTAssertEqual(exported?.speakers?.cleared.map(\.speakerID), ["S1"])
    }

    func testNothingIsExportedWithHistorySyncOff() throws {
        try addPendingRecording()
        history.storeSpeakerTranscript(transcript, forRecordID: recordID)

        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = false
        let offline = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences)

        XCTAssertTrue(offline.userDataSyncHistoryRecords().isEmpty)
    }
}
