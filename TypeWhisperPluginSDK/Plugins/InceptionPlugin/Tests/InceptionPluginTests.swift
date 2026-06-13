import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import InceptionPlugin

final class InceptionPluginTests: XCTestCase {
    func testDefaultModelIsMercury2() throws {
        let host = try PluginTestHostServices()
        let plugin = InceptionPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["mercury-2"])
        XCTAssertEqual(plugin.supportedModels.first?.displayName, "Mercury 2")
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = InceptionPlugin()
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

    func testEditModelsAreNotExposedForChatProcessing() {
        XCTAssertTrue(InceptionFetchedModel(id: "mercury-2", displayName: nil).isChatCompletionsModel)
        XCTAssertFalse(InceptionFetchedModel(id: "mercury-edit-2", displayName: nil).isChatCompletionsModel)
    }
}
