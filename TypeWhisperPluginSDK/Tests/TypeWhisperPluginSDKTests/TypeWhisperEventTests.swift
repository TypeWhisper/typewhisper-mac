import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

final class TypeWhisperEventTests: XCTestCase {
    func testRecorderTranscriptPayloadRetainsCompletionPrecisionAcrossEncoders() throws {
        let payload = RecorderTranscriptReadyPayload(
            recordingID: UUID(), completedAt: Date(timeIntervalSince1970: 1_791_100_000.123456),
            text: "Meeting notes — 中文", audioFilePath: "/recordings/Meeting.wav",
            transcriptFilePath: "/recordings/Meeting.txt"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "recorder")
        XCTAssertEqual(object["completed_at"] as? Double, payload.completedAt.timeIntervalSince1970)
        XCTAssertNil(object["markdown_file"])
        XCTAssertEqual(try JSONDecoder().decode(RecorderTranscriptReadyPayload.self, from: encoded), payload)
    }

    func testRecorderTranscriptPayloadEncodesSpeakersAndMeetingWithSnakeCaseKeys() throws {
        let payload = RecorderTranscriptReadyPayload(
            recordingID: UUID(), text: "Ship it. Agreed.", audioFilePath: "/r/Call.wav",
            transcriptFilePath: "/r/Call.txt", recordedAt: Date(timeIntervalSince1970: 1_791_000_000.5),
            durationSeconds: 1800,
            calendarEvent: RecorderCalendarEvent(
                title: "Weekly", start: Date(timeIntervalSince1970: 1_791_000_000),
                end: Date(timeIntervalSince1970: 1_791_001_800),
                attendees: [RecorderCalendarParticipant(name: "Alex", email: "alex@example.com", status: "accepted", isCurrentUser: true)]
            ),
            speakerState: "ready",
            speakers: [RecorderSpeaker(id: "S1", name: "Me", isMe: true), RecorderSpeaker(id: "S2", name: "Speaker 2", suggestedName: "Kim")],
            speakerSegments: [RecorderSpeakerSegment(start: 0, end: 1.5, speaker: "S1", text: "Ship it.")]
        )
        let encoded = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["recorded_at"] as? Double, 1_791_000_000.5)
        XCTAssertEqual(object["duration_seconds"] as? Double, 1800)
        XCTAssertEqual(object["speaker_state"] as? String, "ready")
        let speakers = try XCTUnwrap(object["speakers"] as? [[String: Any]])
        XCTAssertEqual(speakers.first?["is_me"] as? Bool, true)
        XCTAssertEqual(speakers.last?["suggested_name"] as? String, "Kim")
        XCTAssertEqual((object["speaker_segments"] as? [[String: Any]])?.first?["speaker"] as? String, "S1")
        let event = try XCTUnwrap(object["calendar_event"] as? [String: Any])
        XCTAssertEqual(event["start"] as? Double, 1_791_000_000)
        XCTAssertEqual((event["attendees"] as? [[String: Any]])?.first?["is_current_user"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(RecorderTranscriptReadyPayload.self, from: encoded), payload)
    }

    func testTextCorrectionCommittedPayloadRoundTripsWithoutAppContext() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let capturedAt = Date(timeIntervalSince1970: 1_721_476_800)
        let payload = TextCorrectionCommittedPayload(
            id: id,
            capturedAt: capturedAt,
            originalText: "Ich kaufe ein Auto.",
            correctedText: "Ich kaufe kein Auto.",
            language: "de",
            engineId: "reson8",
            modelId: "typewhisper-dictation",
            appVersion: "1.6.0",
            appBuild: "160",
            platformVersion: "macOS 26.0",
            commitSignal: "return-key",
            sourceChannel: .development
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertNil(object["appName"])
        XCTAssertNil(object["bundleIdentifier"])
        XCTAssertNil(object["url"])
        XCTAssertNil(object["audio"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(TextCorrectionCommittedPayload.self, from: encoded), payload)
    }
}
