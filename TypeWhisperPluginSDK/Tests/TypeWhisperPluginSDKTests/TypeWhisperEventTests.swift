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
