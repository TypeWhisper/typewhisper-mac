import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import Reson8Plugin

final class Reson8PluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testDoesNotAdvertiseMultiLanguageHintCapability() {
        let engine: any TranscriptionEnginePlugin = Reson8Plugin()

        XCTAssertFalse(engine is LanguageHintTranscriptionEnginePlugin)
    }

    func testResolveLanguagePrefersRequestedLanguage() {
        let selection = PluginLanguageSelection(
            requestedLanguage: "nl",
            languageHints: ["de", "en"]
        )

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "nl")
    }

    func testResolveLanguageUsesFirstHintForMultipleHints() {
        let selection = PluginLanguageSelection(languageHints: ["de", "en"])

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "de")
    }

    func testResolveLanguageFallsBackToAutoDetectWithoutUsableLanguage() {
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection()))
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection(languageHints: [""])))
    }

    func testOnlyRecordingsThatFitOneRequestAreStreamed() {
        XCTAssertTrue(Reson8Plugin.streamsAudio(ofDuration: 60))
        XCTAssertTrue(Reson8Plugin.streamsAudio(ofDuration: Reson8Plugin.maximumRequestDuration))
        XCTAssertFalse(Reson8Plugin.streamsAudio(ofDuration: Reson8Plugin.maximumRequestDuration + 1))
    }

    func testTranscriptionSplitsLongRecordingsIntoFiveMinuteRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "reson8-key"])
        let plugin = Reson8Plugin()
        plugin.activate(host: host)

        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":"second"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Just over five minutes, more than one chunk.
        let samples = [Float](repeating: 0.3, count: 16_000 * 301)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: Data(), duration: 301),
            language: "nl",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "first second")
        XCTAssertEqual(result.detectedLanguage, "nl")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            // Five minutes of 16 kHz 16-bit PCM.
            XCTAssertLessThanOrEqual(try XCTUnwrap(request.httpBody).count, 300 * 32_000)
            XCTAssertEqual(request.url?.path, "/v1/speech-to-text/prerecorded")
            XCTAssertTrue(request.url?.query?.contains("language=nl") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ApiKey reson8-key")
        }
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
