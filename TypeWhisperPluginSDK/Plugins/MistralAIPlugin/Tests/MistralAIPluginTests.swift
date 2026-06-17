import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MistralAIPlugin

final class MistralAIPluginTests: XCTestCase {

    func testMistralAIPluginAdvertisesProtocols() {
        let plugin: Any = MistralAIPlugin()
        
        XCTAssertTrue(plugin is any LLMProviderPlugin)
        XCTAssertTrue(plugin is any TranscriptionEnginePlugin)
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
}
