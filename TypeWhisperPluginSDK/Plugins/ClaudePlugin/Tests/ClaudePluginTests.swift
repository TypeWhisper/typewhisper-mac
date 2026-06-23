import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ClaudePlugin

final class ClaudePluginTests: XCTestCase {
    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
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
}
