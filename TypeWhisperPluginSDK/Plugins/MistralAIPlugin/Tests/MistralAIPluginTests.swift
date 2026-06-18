import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MistralAIPlugin

final class MistralAIPluginTests: XCTestCase {

    func testMistralAIPluginAdvertisesProtocols() {
        let plugin: Any = MistralAIPlugin()
        
        XCTAssertTrue(plugin is any LLMProviderPlugin)
        XCTAssertTrue(plugin is any TranscriptionEnginePlugin)
        XCTAssertTrue(plugin is any LLMProviderIdentityProviding)
        XCTAssertTrue(plugin is any LLMModelSelectable)
    }

    func testMistralAIModelsAreEmptyWithoutAPIKey() {
        let plugin = MistralAIPlugin()
        XCTAssertTrue(plugin.supportedModels.isEmpty)
        XCTAssertTrue(plugin.transcriptionModels.isEmpty)
    }

    func testMistralAIIsAvailable() throws {
        let plugin = MistralAIPlugin()
        XCTAssertFalse(plugin.isAvailable)
        
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        plugin.activate(host: host)
        
        XCTAssertTrue(plugin.isAvailable)
    }

    func testMistralAITranscriptionModelsIncludeVoxtral() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        let models = plugin.transcriptionModels
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.id == "voxtral-mini-latest" })
    }

    func testMistralAILLMModelsIncludeMistralSmall() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        let models = plugin.supportedModels
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.id == "mistral-small-latest" })
        XCTAssertTrue(models.contains { $0.id == "mistral-large-latest" })
    }

    func testMistralAISelectsModels() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        plugin.selectLLMModel("mistral-large-latest")
        plugin.selectModel("voxtral-mini-latest")
        
        XCTAssertEqual(plugin.selectedLLMModelId, "mistral-large-latest")
        XCTAssertEqual(plugin.selectedModelId, "voxtral-mini-latest")
    }

    func testMistralAIProviderContractAndIdentity() throws {
        let plugin = MistralAIPlugin()
        
        // Identity checks
        XCTAssertEqual(plugin.providerId, "mistral", "Stable provider ID should be 'mistral'")
        XCTAssertEqual(plugin.providerDisplayName, "Mistral AI")
        
        // LLMModelSelectable checks
        let selectable: any LLMModelSelectable = plugin
        XCTAssertEqual(selectable.defaultModelId, "mistral-small-latest")
        XCTAssertNil(selectable.preferredModelId ?? nil)
        
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        plugin.activate(host: host)
        plugin.selectLLMModel("pixtral-12b-2409")
        
        XCTAssertEqual(selectable.preferredModelId ?? nil, "pixtral-12b-2409")
    }
}
