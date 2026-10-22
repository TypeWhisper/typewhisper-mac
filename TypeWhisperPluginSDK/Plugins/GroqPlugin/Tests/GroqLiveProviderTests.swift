import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

/// Opt-in provider smoke for the LLM model list and default model. The key
/// comes from the test process environment and is never printed by this test.
final class GroqLiveProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PluginHTTPClientTestHarness.reset()
    }

    func testLiveRefreshReplacesRetiredSelectionWithAnsweringDefault() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TYPEWHISPER_GROQ_LIVE_TEST"] == "1",
              let apiKey = environment["TYPEWHISPER_GROQ_LIVE_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("Opt-in Groq provider test requires TYPEWHISPER_GROQ_LIVE_TEST=1 and an API key.")
        }
        // State of an install that fetched its list before Groq retired Llama 3.3 70B.
        let host = try PluginTestHostServices(
            defaults: [
                GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile",
                GroqPlugin.fetchedLLMModelsKey: try JSONSerialization.data(
                    withJSONObject: [["id": "llama-3.3-70b-versatile"], ["id": "openai/gpt-oss-120b"]]
                ),
            ],
            secrets: ["api-key": apiKey]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let refresh = try XCTUnwrap(plugin.llmModelRefreshTask)
        await refresh.value

        let modelIds = plugin.supportedModels.map(\.id)
        XCTAssertTrue(modelIds.contains(GroqPlugin.curatedDefaultLLMModelId), "Groq lists \(modelIds)")
        XCTAssertEqual(plugin.defaultModelId, GroqPlugin.curatedDefaultLLMModelId)
        // Enterprise contracts keep Llama 3.3 70B; on-demand accounts no longer list it.
        if modelIds.contains("llama-3.3-70b-versatile") {
            XCTAssertEqual(plugin.preferredModelId, "llama-3.3-70b-versatile")
        } else {
            XCTAssertNil(plugin.preferredModelId)
        }

        let reply = try await plugin.process(
            systemPrompt: "Answer with exactly one word.",
            userText: "Reply with OK.",
            model: nil
        )
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
