import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GeminiPlugin

final class GeminiPluginTests: XCTestCase {
    private static let cachedLLMModelsKey = "fetchedLLMModels.v2"
    private static let selectedLLMModelKey = "selectedLLMModel"

    private static func cachedModelsData() throws -> Data {
        try JSONEncoder().encode([
            GeminiFetchedModel(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash"),
            GeminiFetchedModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            GeminiFetchedModel(id: "gemini-flash-latest", displayName: "Gemini Flash Latest"),
        ])
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
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

    func testFreshActivationDoesNotExposeOrPersistOldestFetchedModel() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.cachedLLMModelsKey: try Self.cachedModelsData()]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.first?.id, "gemini-2.0-flash")
        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "fresh activation must not expose the alphabetically-oldest fetched model as a preference"
        )
        XCTAssertNil(
            host.userDefault(forKey: Self.selectedLLMModelKey),
            "fresh activation must not persist a model the user never selected"
        )
    }

    func testInvalidStoredSelectionIsNotReplacedByOldestFetchedModel() throws {
        let host = try PluginTestHostServices(
            defaults: [
                Self.cachedLLMModelsKey: try Self.cachedModelsData(),
                Self.selectedLLMModelKey: "gemini-removed-model",
            ]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "a stale selection must not be normalized into a fallback preference"
        )
        XCTAssertEqual(
            host.userDefault(forKey: Self.selectedLLMModelKey) as? String,
            "gemini-removed-model",
            "the stored selection is kept so it can re-validate if the model reappears"
        )
    }

    func testValidStoredSelectionSurvivesActivation() throws {
        let host = try PluginTestHostServices(
            defaults: [
                Self.cachedLLMModelsKey: try Self.cachedModelsData(),
                Self.selectedLLMModelKey: "gemini-2.5-flash",
            ]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            (plugin as? LLMModelSelectable)?.preferredModelId,
            "gemini-2.5-flash"
        )
    }
}
