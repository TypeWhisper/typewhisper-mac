import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAIPlugin

/// The token usage the OpenAI plugin reports for its LLM requests. Chat
/// Completions report through `PluginOpenAIChatHelper`; the Responses API
/// client reports on its own.
final class OpenAIUsageReportingTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testResponsesRequestReportsItsUsage() async throws {
        let (result, reports) = try await Self.processCollectingUsage(
            model: "gpt-5.5",
            url: "https://api.openai.com/v1/responses",
            body: #"""
            {"model":"gpt-5.5-2026-08-01","output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}],
             "usage":{"input_tokens":310,"output_tokens":95,"total_tokens":405,
                      "output_tokens_details":{"reasoning_tokens":64}}}
            """#
        )

        XCTAssertEqual(result, "Done")
        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 310, outputTokens: 95, model: "gpt-5.5-2026-08-01")])
    }

    func testResponsesRequestWithoutUsageReportsNothing() async throws {
        let (result, reports) = try await Self.processCollectingUsage(
            model: "gpt-5.5",
            url: "https://api.openai.com/v1/responses",
            body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#
        )

        XCTAssertEqual(result, "Done")
        XCTAssertEqual(reports, [])
    }

    func testChatCompletionsRequestReportsItsUsageThroughTheHelper() async throws {
        let (result, reports) = try await Self.processCollectingUsage(
            model: "gpt-4.1-mini",
            url: "https://api.openai.com/v1/chat/completions",
            body: #"""
            {"model":"gpt-4.1-mini-2025-04-14","choices":[{"message":{"content":"Done"}}],
             "usage":{"prompt_tokens":52,"completion_tokens":3,"total_tokens":55}}
            """#
        )

        XCTAssertEqual(result, "Done")
        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 52, outputTokens: 3, model: "gpt-4.1-mini-2025-04-14")])
    }

    /// Runs one LLM request with an API key, answered with `body`, and returns
    /// the result and the usage reported meanwhile.
    private static func processCollectingUsage(
        model: String,
        url: String,
        body: String
    ) async throws -> (result: String, reports: [PluginLLMUsage]) {
        let host = try PluginTestHostServices(
            defaults: ["selectedLLMModel": model],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(body.utf8),
                    HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                ),
            ])
        }
        let collector = PluginLLMUsageCollector()
        let result = try await PluginLLMUsageReporting.$collector.withValue(collector) {
            try await plugin.process(systemPrompt: "Fix grammar", userText: "hello", model: nil)
        }
        XCTAssertEqual(store.sessions.first?.requestedRequests.first?.url?.absoluteString, url)
        return (result, collector.reports)
    }
}
