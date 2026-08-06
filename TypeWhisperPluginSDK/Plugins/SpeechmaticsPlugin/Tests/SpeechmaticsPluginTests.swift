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

    // Language packs documented at docs.speechmatics.com/introduction/supported-languages
    private static let documentedLanguagePacks: Set<String> = [
        "auto", "ar", "ba", "eu", "be", "bn", "bg", "yue", "ca", "hr",
        "cs", "da", "nl", "en", "eo", "et", "fi", "fr", "gl", "de",
        "el", "he", "hi", "hu", "id", "ia", "ga", "it", "ja", "ko",
        "lv", "lt", "ms", "mt", "cmn", "mr", "mn", "no", "fa", "pl",
        "pt", "ro", "ru", "sk", "sl", "es", "sw", "sv", "ta", "th",
        "tr", "uk", "ur", "ug", "vi", "cy",
    ]

    func testChineseResolvesToMandarinLanguagePack() {
        XCTAssertEqual(SpeechmaticsPlugin.languagePack(for: "zh"), "cmn")
    }

    func testAutoDetectIsRequestedWhenNoLanguageIsSelected() {
        XCTAssertEqual(SpeechmaticsPlugin.languagePack(for: nil), "auto")
        XCTAssertEqual(SpeechmaticsPlugin.languagePack(for: ""), "auto")
    }

    func testUnaliasedLanguagesArePassedThrough() {
        XCTAssertEqual(SpeechmaticsPlugin.languagePack(for: "de"), "de")
        XCTAssertEqual(SpeechmaticsPlugin.languagePack(for: "yue"), "yue")
    }

    func testEveryAdvertisedLanguageResolvesToADocumentedPack() {
        let plugin = SpeechmaticsPlugin()
        for code in plugin.supportedLanguages {
            let pack = SpeechmaticsPlugin.languagePack(for: code)
            XCTAssertTrue(
                Self.documentedLanguagePacks.contains(pack),
                "\(code) resolves to \(pack), which Speechmatics rejects with HTTP 400"
            )
        }
    }

    func testRealtimeStreamingIsSkippedWhenLanguageIdentificationIsNeeded() {
        XCTAssertFalse(SpeechmaticsPlugin.supportsRealtimeStreaming(language: nil))
        XCTAssertFalse(SpeechmaticsPlugin.supportsRealtimeStreaming(language: ""))
    }

    func testRealtimeStreamingIsUsedForExplicitLanguages() {
        XCTAssertTrue(SpeechmaticsPlugin.supportsRealtimeStreaming(language: "de"))
        XCTAssertTrue(SpeechmaticsPlugin.supportsRealtimeStreaming(language: "zh"))
    }

    func testUnsupportedLanguagesAreNoLongerAdvertised() {
        let plugin = SpeechmaticsPlugin()
        for code in ["gu", "is", "ka", "kk", "ml", "mk", "pa", "sq", "sr", "te"] {
            XCTAssertFalse(
                plugin.supportedLanguages.contains(code),
                "\(code) has no Speechmatics language pack"
            )
        }
    }
}
