import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

@objc(MockEffortAwareLLMProvider)
private final class MockEffortAwareLLMProvider: NSObject,
    LLMProviderPlugin,
    LLMEffortControllableProvider,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.mock.effort"
    static let pluginName = "Mock Effort Provider"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerName: String { "Mock Effort" }
    var isAvailable: Bool { true }
    var supportedModels: [PluginModelInfo] {
        [PluginModelInfo(id: "reasoning-model", displayName: "Reasoning Model")]
    }

    func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo] {
        guard model == "reasoning-model" else { return [] }
        return [
            PluginLLMEffortInfo(id: "low", displayName: "Low", detail: "Faster"),
            PluginLLMEffortInfo(id: "high", displayName: "High", detail: "Deeper reasoning"),
        ]
    }

    func defaultEffortId(for model: String?) -> String? {
        model == "reasoning-model" ? "low" : nil
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        "legacy"
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        effort: String?
    ) async throws -> String {
        [systemPrompt, userText, model, effort].compactMap { $0 }.joined(separator: "|")
    }
}

final class LLMEffortSupportTests: XCTestCase {
    func testEffortCapabilityIsOptionalAndModelSpecific() async throws {
        let provider = MockEffortAwareLLMProvider()
        let capability: any LLMEffortControllableProvider = provider

        XCTAssertEqual(capability.supportedEfforts(for: "reasoning-model").map(\.id), ["low", "high"])
        XCTAssertEqual(capability.supportedEfforts(for: "reasoning-model").map(\.detail), ["Faster", "Deeper reasoning"])
        XCTAssertEqual(capability.defaultEffortId(for: "reasoning-model"), "low")
        XCTAssertTrue(capability.supportedEfforts(for: "legacy-model").isEmpty)
        let result = try await capability.process(
            systemPrompt: "system",
            userText: "input",
            model: "reasoning-model",
            effort: "high"
        )
        XCTAssertEqual(result, "system|input|reasoning-model|high")
    }
}
