import XCTest
@testable import SpeechmaticsPlugin

final class SpeechmaticsPluginTests: XCTestCase {
    func testUSRegionUsesDocumentedBatchEndpoint() {
        XCTAssertEqual(
            SpeechmaticsPlugin.batchHost(forRegion: "us"),
            "us1.asr.api.speechmatics.com"
        )
    }

    func testEURegionAndUnknownRegionsUseDefaultBatchEndpoint() {
        XCTAssertEqual(SpeechmaticsPlugin.batchHost(forRegion: "eu"), "asr.api.speechmatics.com")
        XCTAssertEqual(SpeechmaticsPlugin.batchHost(forRegion: nil), "asr.api.speechmatics.com")
        XCTAssertEqual(SpeechmaticsPlugin.batchHost(forRegion: "unknown"), "asr.api.speechmatics.com")
    }

    func testBatchHostsNeverUseTheRealtimeRegionLabel() {
        for region in ["eu", "us", "unknown", nil] {
            XCTAssertFalse(
                SpeechmaticsPlugin.batchHost(forRegion: region).hasPrefix("usa."),
                "\"usa\" is a realtime-only label and is unregistered in the batch namespace"
            )
        }
    }

    func testRealtimeHostsAreUnchanged() {
        XCTAssertEqual(SpeechmaticsPlugin.wsHost(forRegion: "us"), "usa.rt.speechmatics.com")
        XCTAssertEqual(SpeechmaticsPlugin.wsHost(forRegion: "eu"), "eu2.rt.speechmatics.com")
        XCTAssertEqual(SpeechmaticsPlugin.wsHost(forRegion: nil), "eu2.rt.speechmatics.com")
    }
}
