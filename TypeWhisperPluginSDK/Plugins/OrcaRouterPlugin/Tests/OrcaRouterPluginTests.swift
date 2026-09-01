import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OrcaRouterPlugin

final class OrcaRouterPluginTests: XCTestCase {
    func testProviderIdentityAndAvailability() throws {
        let host = try PluginTestHostServices()
        let plugin = OrcaRouterPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.providerId, "orcarouter")
        XCTAssertEqual(plugin.providerName, "OrcaRouter")
        XCTAssertEqual(plugin.providerDisplayName, "OrcaRouter")
        XCTAssertFalse(plugin.isAvailable)
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = OrcaRouterPlugin()
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

    func testFallbackModelsExposeAutoRouterFirst() throws {
        let host = try PluginTestHostServices()
        let plugin = OrcaRouterPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.first?.id, "orcarouter/auto")
        XCTAssertEqual(plugin.supportedModels.first?.displayName, "Auto Router")
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "orcarouter/fusion" })
    }

    func testSelectedModelPersistsAcrossActivation() throws {
        let host = try PluginTestHostServices()
        let plugin = OrcaRouterPlugin()
        plugin.activate(host: host)

        plugin.selectLLMModel("orcarouter/fusion-mini")
        plugin.deactivate()

        let reloaded = OrcaRouterPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "orcarouter/fusion-mini")
        XCTAssertEqual(reloaded.selectedLLMModelId, "orcarouter/fusion-mini")
    }

    func testFetchedModelsOverrideFallbacks() throws {
        let host = try PluginTestHostServices()
        let plugin = OrcaRouterPlugin()
        plugin.activate(host: host)

        let fetched = [
            OrcaRouterFetchedModel(id: "anthropic/claude-opus-4.8", displayName: nil),
            OrcaRouterFetchedModel(id: "openai/gpt-oss-120b", displayName: nil),
        ]
        plugin.setFetchedModels(fetched)

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["anthropic/claude-opus-4.8", "openai/gpt-oss-120b"])
    }
}
