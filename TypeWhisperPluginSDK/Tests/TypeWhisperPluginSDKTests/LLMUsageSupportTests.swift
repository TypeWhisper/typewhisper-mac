import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

final class LLMUsageSupportTests: XCTestCase {
    func testReportWithoutCollectorDoesNothing() {
        XCTAssertNil(PluginLLMUsageReporting.collector)
        PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: 1, outputTokens: 2))
    }

    func testCollectorReceivesEveryReportOfTheTaskAndItsChildTasks() async {
        let collector = PluginLLMUsageCollector()

        await PluginLLMUsageReporting.$collector.withValue(collector) {
            PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: 10, outputTokens: 2, model: "first"))
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: 5, outputTokens: 1))
                }
            }
        }

        XCTAssertEqual(collector.reports, [
            PluginLLMUsage(inputTokens: 10, outputTokens: 2, model: "first"),
            PluginLLMUsage(inputTokens: 5, outputTokens: 1),
        ])
    }

    func testReportsOutsideTheCollectorScopeAreNotRecorded() async {
        let collector = PluginLLMUsageCollector()
        await PluginLLMUsageReporting.$collector.withValue(collector) {
            await Task.detached {
                PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: 3, outputTokens: 4))
            }.value
        }
        PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: 1, outputTokens: 1))

        XCTAssertEqual(collector.reports, [])
    }

    func testReportsWithoutTokenCountsAreIgnored() {
        let collector = PluginLLMUsageCollector()
        PluginLLMUsageReporting.$collector.withValue(collector) {
            PluginLLMUsageReporting.report(nil)
            PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: nil, outputTokens: nil, model: "m"))
            PluginLLMUsageReporting.report(PluginLLMUsage(inputTokens: nil, outputTokens: 7))
        }

        XCTAssertEqual(collector.reports, [PluginLLMUsage(inputTokens: nil, outputTokens: 7)])
    }

    func testInitDropsNegativeCountsAndBlankModels() {
        let usage = PluginLLMUsage(inputTokens: -1, outputTokens: 4, model: "  ")

        XCTAssertNil(usage.inputTokens)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertNil(usage.model)
    }

    func testOpenAICompatibleReadsChatCompletionsUsageAndModel() throws {
        let response = try json(#"""
        {"model":"gpt-4o-mini-2024-07-18","choices":[],
         "usage":{"prompt_tokens":812,"completion_tokens":96,"total_tokens":908,
                  "completion_tokens_details":{"reasoning_tokens":64}}}
        """#)

        XCTAssertEqual(
            PluginLLMUsage.openAICompatible(from: response),
            PluginLLMUsage(inputTokens: 812, outputTokens: 96, model: "gpt-4o-mini-2024-07-18")
        )
    }

    func testOpenAICompatibleReadsResponsesAPIUsage() throws {
        let response = try json(#"{"model":"gpt-5","usage":{"input_tokens":40,"output_tokens":12}}"#)

        XCTAssertEqual(
            PluginLLMUsage.openAICompatible(from: response),
            PluginLLMUsage(inputTokens: 40, outputTokens: 12, model: "gpt-5")
        )
    }

    func testOpenAICompatibleCountsReasoningTokensThatOnlyTheTotalIncludes() throws {
        // Gemini's OpenAI-compatible endpoint: thinking tokens are in the total only.
        let response = try json(#"{"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":380}}"#)

        XCTAssertEqual(
            PluginLLMUsage.openAICompatible(from: response),
            PluginLLMUsage(inputTokens: 100, outputTokens: 280)
        )
    }

    func testOpenAICompatibleKeepsTheCompletionCountWhenTheTotalAddsNothing() throws {
        let response = try json(#"{"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120}}"#)

        XCTAssertEqual(
            PluginLLMUsage.openAICompatible(from: response),
            PluginLLMUsage(inputTokens: 100, outputTokens: 20)
        )
    }

    func testOpenAICompatibleReturnsNilWithoutUsage() throws {
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: try json(#"{"model":"m","choices":[]}"#)))
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: try json(#"{"usage":null}"#)))
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: try json(#"{"usage":{"total_tokens":9}}"#)))
    }

    func testOpenAICompatibleReadsRawResponseBodies() {
        let body = Data(#"{"model":"m","usage":{"prompt_tokens":3,"completion_tokens":2}}"#.utf8)
        XCTAssertEqual(PluginLLMUsage.openAICompatible(from: body), PluginLLMUsage(inputTokens: 3, outputTokens: 2, model: "m"))
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: Data("not json".utf8)))
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: Data(#"[{"usage":{"prompt_tokens":3}}]"#.utf8)))
        XCTAssertNil(PluginLLMUsage.openAICompatible(from: Data()))
    }

    func testAnthropicMessagesCountsCachedPromptTokensAsInput() throws {
        let response = try json(#"""
        {"model":"claude-sonnet-4-5-20250929",
         "usage":{"input_tokens":20,"cache_creation_input_tokens":100,"cache_read_input_tokens":300,"output_tokens":42}}
        """#)

        XCTAssertEqual(
            PluginLLMUsage.anthropicMessages(from: response),
            PluginLLMUsage(inputTokens: 420, outputTokens: 42, model: "claude-sonnet-4-5-20250929")
        )
    }

    func testAnthropicMessagesReturnsNilWithoutUsage() throws {
        XCTAssertNil(PluginLLMUsage.anthropicMessages(from: try json(#"{"model":"claude"}"#)))
    }

    func testTokenCountAcceptsOnlyNonNegativeWholeNumbers() throws {
        let values = try json(#"{"int":12,"whole":12.0,"fraction":1.5,"negative":-3,"bool":true,"text":"12"}"#)

        XCTAssertEqual(PluginLLMUsage.tokenCount(values["int"]), 12)
        XCTAssertEqual(PluginLLMUsage.tokenCount(values["whole"]), 12)
        XCTAssertNil(PluginLLMUsage.tokenCount(values["fraction"]))
        XCTAssertNil(PluginLLMUsage.tokenCount(values["negative"]))
        XCTAssertNil(PluginLLMUsage.tokenCount(values["bool"]))
        XCTAssertNil(PluginLLMUsage.tokenCount(values["text"]))
        XCTAssertNil(PluginLLMUsage.tokenCount(nil))
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
