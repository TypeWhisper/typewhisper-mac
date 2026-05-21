import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAICompatiblePlugin

final class OpenAICompatiblePluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testSetBaseURLNormalizesTrailingSlashAndV1Suffix() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setBaseURL("http://localhost:11434/v1/")

        XCTAssertEqual(host.userDefault(forKey: "baseURL") as? String, "http://localhost:11434")
        XCTAssertTrue(host.capabilitiesChangedCount >= 1)
    }

    func testModelSelectionsPersistAcrossActivation() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "http://localhost:11434"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.selectModel("whisper-1")
        plugin.selectLLMModel("gpt-4.1-mini")
        plugin.deactivate()

        let reloaded = OpenAICompatiblePlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(reloaded.selectedModelId, "whisper-1")
        XCTAssertEqual(reloaded.selectedLLMModelId, "gpt-4.1-mini")
    }

    func testFetchModelsSendsBearerTokenAndSortsIDs() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test"],
            secrets: ["api-key": "secret-token"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"z-model"},{"id":"a-model"}]}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                )
            ])
        }

        let models = await plugin.fetchModels()

        XCTAssertEqual(models.map(\.id), ["a-model", "z-model"])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
    }

    func testValidateConnectionReturnsTrueForHTTP200() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                )
            ])
        }

        let result = await plugin.validateConnection()

        XCTAssertTrue(result)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/models"])
    }

    func testTranscribeUsesLongTimeoutForLocalCompatibleServers() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test",
                "selectedModel": "large-v3",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 200)
                )
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/audio/transcriptions"])
        XCTAssertEqual(store.sessions[0].requestedRequests.first?.timeoutInterval, 600)
    }

    func testProcessFailsWithoutSelectedModel() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.process(systemPrompt: "Fix", userText: "hello", model: nil)
            XCTFail("Expected noModelSelected")
        } catch let error as PluginChatError {
            guard case .noModelSelected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscribeFailsWithoutSelectedModel() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let audio = AudioData(samples: [0, 0, 0], wavData: Data(), duration: 0.1)

        do {
            _ = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
            XCTFail("Expected noModelSelected")
        } catch let error as PluginTranscriptionError {
            guard case .noModelSelected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
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
