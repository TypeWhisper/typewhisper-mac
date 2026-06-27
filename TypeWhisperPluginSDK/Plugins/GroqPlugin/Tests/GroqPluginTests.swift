import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

final class GroqPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testTranscribeUsesLongTimeoutForLargerAudioUploads() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/openai/v1/audio/transcriptions"])
        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 600)

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body.prefix(1_024), as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(bodyText.contains("Content-Type: audio/mp4"))
        XCTAssertFalse(bodyText.contains(#"filename="audio.wav""#))
    }

    func testTranscribeRetriesWithWavWhenGroqRejectsM4AUpload() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?","type":"invalid_request_error"}}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 400
                    )
                ),
                .success(
                    Data(#"{"text":"hello","language":"de"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )
        let result = try await plugin.transcribe(
            audio: audio,
            language: "de",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "hello")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(store.sessions[0].requestedPaths, [
            "/openai/v1/audio/transcriptions",
            "/openai/v1/audio/transcriptions",
        ])

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        XCTAssertEqual(requests[1].timeoutInterval, 600)
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
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
