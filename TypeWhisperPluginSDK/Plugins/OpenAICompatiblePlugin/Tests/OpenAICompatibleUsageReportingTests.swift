import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAICompatiblePlugin

/// The token usage the OpenAI Compatible plugin reports for its LLM requests,
/// through Chat Completions and through the Responses API.
final class OpenAICompatibleUsageReportingTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testChatCompletionReportsItsUsage() async throws {
        let (reply, reports) = try await Self.processCollectingUsage(api: .chatCompletions, body: #"""
        {"model":"llama3.2:3b","choices":[{"message":{"content":"ok"}}],
         "usage":{"prompt_tokens":61,"completion_tokens":2,"total_tokens":63}}
        """#)

        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 61, outputTokens: 2, model: "llama3.2:3b")])
    }

    func testChatCompletionWithoutUsageReportsNothing() async throws {
        let (reply, reports) = try await Self.processCollectingUsage(
            api: .chatCompletions,
            body: #"{"choices":[{"message":{"content":"ok"}}]}"#
        )

        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(reports, [])
    }

    func testCutOffChatCompletionFailsButReportsItsUsage() async throws {
        let (reply, reports) = try await Self.processCollectingUsage(api: .chatCompletions, body: #"""
        {"choices":[{"message":{"content":"half a sen"},"finish_reason":"length"}],
         "usage":{"prompt_tokens":40,"completion_tokens":4096}}
        """#)

        XCTAssertNil(reply, "a cut-off reply must still fail")
        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 40, outputTokens: 4096)])
    }

    func testResponsesRequestReportsItsUsage() async throws {
        let (reply, reports) = try await Self.processCollectingUsage(api: .responses, body: #"""
        {"model":"reasoning-model","output_text":"ok",
         "usage":{"input_tokens":75,"output_tokens":30,"total_tokens":105}}
        """#)

        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 75, outputTokens: 30, model: "reasoning-model")])
    }

    func testResponsesRequestWithoutUsageReportsNothing() async throws {
        let (reply, reports) = try await Self.processCollectingUsage(api: .responses, body: #"{"output_text":"ok"}"#)

        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(reports, [])
    }

    /// Runs one LLM request through `api`, answered with `body`, and returns
    /// the reply (nil when the request failed) and the usage reported meanwhile.
    private static func processCollectingUsage(
        api: OpenAICompatibleLLMAPI,
        body: String
    ) async throws -> (reply: String?, reports: [PluginLLMUsage]) {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test",
                "selectedLLMModel": "reasoning-model",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setLLMAPI(api, for: plugin.providerId)
        let path = api == .responses ? "/v1/responses" : "/v1/chat/completions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(body.utf8),
                    HTTPURLResponse(
                        url: URL(string: "https://example.test\(path)")!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                ),
            ])
        }
        let collector = PluginLLMUsageCollector()
        let reply = try? await PluginLLMUsageReporting.$collector.withValue(collector) {
            try await plugin.process(systemPrompt: "", userText: "hello", model: nil)
        }
        XCTAssertEqual(store.sessions.first?.requestedRequests.first?.url?.path, path)
        return (reply, collector.reports)
    }
}
