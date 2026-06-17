import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import SonioxPlugin

final class SonioxPluginTests: XCTestCase {
    func testDefaultRealtimeModelUsesRTV5AndPersistsSelection() throws {
        let host = try PluginTestHostServices()
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "stt-rt-v5")
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["stt-rt-v5"])
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "stt-rt-v5")
    }

    func testRetiredRealtimeModelMigratesToRTV5() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "stt-rt-v4"])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "stt-rt-v5")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "stt-rt-v5")
    }

    func testCreateTranscriptionRequestUsesAsyncV5Model() throws {
        let request = try SonioxPlugin.makeCreateTranscriptionRequest(
            fileId: "file_123",
            language: "de",
            languageHints: ["en", "de"],
            translate: true,
            apiKey: "soniox-key",
            prompt: nil
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.soniox.com/v1/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["file_id"] as? String, "file_123")
        XCTAssertEqual(body["model"] as? String, "stt-async-v5")
        XCTAssertEqual(body["language_hints"] as? [String], ["en", "de"])

        let translation = try XCTUnwrap(body["translation"] as? [String: Any])
        XCTAssertEqual(translation["type"] as? String, "one_way")
        XCTAssertEqual(translation["target_language"] as? String, "en")
    }

    func testSourceProgressUsesFinalOriginalTokenTiming() {
        let progress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1500],
                ["text": "hola", "is_final": true, "end_ms": 9000, "translation_status": "translation"],
                ["text": "draft", "is_final": false, "end_ms": 8000],
            ],
            totalDuration: 10
        )

        XCTAssertEqual(progress?.processedDuration, 1.5)
        XCTAssertEqual(progress?.totalDuration, 10)
        XCTAssertEqual(progress?.fractionCompleted, 0.15)
    }

    func testSourceProgressRequiresTimedFinalOriginalTokens() {
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "translated", "is_final": true, "end_ms": 2000, "translation_status": "translation"],
                ["text": "untimed", "is_final": true],
            ],
            totalDuration: 10
        ))

        let clampedProgress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "late", "is_final": true, "end_ms": "12000"],
            ],
            totalDuration: 10
        )
        XCTAssertEqual(clampedProgress?.processedDuration, 10)
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1000],
            ],
            totalDuration: 0
        ))
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
