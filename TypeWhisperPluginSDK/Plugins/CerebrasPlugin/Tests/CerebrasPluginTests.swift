import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import CerebrasPlugin

final class CerebrasPluginTests: XCTestCase {
    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = CerebrasPlugin()
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

    func testReasoningEffortFollowsWorkflowThenSettingsAndSkipsModelsWithoutLevels() throws {
        let host = try PluginTestHostServices()
        let plugin = CerebrasPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedEfforts(for: "gpt-oss-120b").map(\.id), ["low", "medium", "high"])
        XCTAssertEqual(plugin.defaultEffortId(for: "gpt-oss-120b"), "medium")
        XCTAssertNil(
            plugin.requestReasoningEffort(nil, forModelId: "gpt-oss-120b"),
            "Without a picked level the request keeps Cerebras' default"
        )

        plugin.setReasoningEffort("low", forModelId: "gpt-oss-120b")
        XCTAssertEqual(plugin.requestReasoningEffort(nil, forModelId: "gpt-oss-120b"), "low")
        XCTAssertEqual(plugin.requestReasoningEffort("high", forModelId: "gpt-oss-120b"), "high")
        XCTAssertEqual(plugin.requestReasoningEffort("none", forModelId: "gpt-oss-120b"), "low")

        let reloaded = CerebrasPlugin()
        reloaded.activate(host: host)
        XCTAssertEqual(reloaded.defaultEffortId(for: "gpt-oss-120b"), "low")

        XCTAssertTrue(plugin.supportedEfforts(for: "some-model-without-levels").isEmpty)
        XCTAssertNil(plugin.requestReasoningEffort("low", forModelId: "some-model-without-levels"))
    }

    func testDeprecatedModelSelectionMovesToGPTOSS() throws {
        let host = try PluginTestHostServices()
        host.setUserDefault("llama3.1-8b", forKey: "selectedLLMModel")
        let plugin = CerebrasPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-oss-120b")
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gpt-oss-120b"])
        XCTAssertEqual(plugin.defaultEffortId(for: "zai-glm-4.7"), "medium")

        plugin.setFetchedModels([
            CerebrasFetchedModel(id: "gpt-oss-120b", displayName: nil),
            CerebrasFetchedModel(id: "llama3.1-8b", displayName: nil),
            CerebrasFetchedModel(id: "qwen-3.8-27b", displayName: nil),
        ])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gpt-oss-120b", "qwen-3.8-27b"])
    }
}
