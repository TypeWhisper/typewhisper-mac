import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ParakeetPlugin

final class ParakeetPluginTests: XCTestCase {
    private actor RequestRecorder {
        private var request: URLRequest?

        func set(_ request: URLRequest) {
            self.request = request
        }

        func get() -> URLRequest? {
            request
        }
    }

    private func makePlugin(restoresModelOnActivate: Bool = false) -> ParakeetPlugin {
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = restoresModelOnActivate
        return plugin
    }

    func testActivationPromotesPersistedLoadedModelToSelectedModelWhenSelectionMissing() throws {
        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testActivationKeepsPersistedSelectedModelVisibleBeforeRestoreCompletes() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v2",
            "loadedModel": "parakeet-tdt-0.6b-v2",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v2")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v2")
    }

    func testActivationDoesNotMarkPluginConfiguredBeforeRestoreSucceeds() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadWithoutClearingPersistenceKeepsSelectedAndLoadedModelMarkers() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: false)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadClearingPersistenceKeepsSelectedModelAndRemovesLoadedModelMarker() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: true)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testActivationLoadsStoredHuggingFaceToken() throws {
        let host = try PluginTestHostServices(secrets: ["hf-token": "hf_parakeet_saved"])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.huggingFaceToken, "hf_parakeet_saved")
    }

    func testDisablesTranscriptPreviewFallback() throws {
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = ParakeetPlugin()

        XCTAssertFalse(fallbackPolicy.allowsTranscriptPreviewFallback)
    }

    func testProvidesLiveTranscriptionSessionCapability() throws {
        let plugin = ParakeetPlugin()
        let livePlugin: any LiveTranscriptionCapablePlugin = plugin
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = plugin

        XCTAssertTrue(livePlugin.supportsStreaming)
        XCTAssertFalse(fallbackPolicy.allowsTranscriptPreviewFallback)
    }

    func testLivePreviewConfigUsesStableStreamingWindow() throws {
        XCTAssertEqual(parakeetLivePreviewConfig.chunkSeconds, 11.0)
        XCTAssertEqual(parakeetLivePreviewConfig.rightContextSeconds, 2.0)
        XCTAssertEqual(parakeetLivePreviewConfig.minContextForConfirmation, 10.0)
    }

    func testDictionaryTermsSupportReflectsStoredBoostingPreference() throws {
        let defaultHost = try PluginTestHostServices()
        let defaultPlugin = makePlugin()
        defaultPlugin.activate(host: defaultHost)
        XCTAssertEqual(defaultPlugin.dictionaryTermsSupport, .requiresPluginSetting)

        let enabledHost = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let enabledPlugin = makePlugin()
        enabledPlugin.activate(host: enabledHost)
        XCTAssertEqual(enabledPlugin.dictionaryTermsSupport, .supported)
    }

    func testSettingsDismissalRequiresOnlyBaseModelReadiness() throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.canDismissSettingsAfterSetup)

        plugin.ctcModelState = .ready
        XCTAssertFalse(plugin.canDismissSettingsAfterSetup)

        plugin.modelState = .ready
        plugin.ctcModelState = .downloading
        XCTAssertTrue(plugin.canDismissSettingsAfterSetup)
    }

    func testEnablingVocabularyBoostingPersistsAndNotifiesCapabilityChange() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.setBoostingEnabled(true)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, true)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setBoostingEnabled(true)

        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testDisablingVocabularyBoostingPersistsClearsVocabularyAndHidesCtcActivity() throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.lastConfiguredPrompt = "TypeWhisper Madison"
        plugin.lastBoostingTermCount = 2
        plugin.ctcModelState = .downloading
        XCTAssertEqual(plugin.currentSettingsActivity?.message, "Downloading vocabulary model")

        plugin.setBoostingEnabled(false)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, false)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)
        XCTAssertNil(plugin.lastConfiguredPrompt)
        XCTAssertEqual(plugin.lastBoostingTermCount, 0)
        XCTAssertNil(plugin.currentSettingsActivity)
        plugin.ctcModelState = .error("Vocabulary model failed")
        XCTAssertNil(plugin.currentSettingsActivity)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setBoostingEnabled(false)

        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testStoresAndClearsHuggingFaceTokenSecret() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.setHuggingFaceToken("  hf_parakeet_saved  ")
        XCTAssertEqual(plugin.huggingFaceToken, "hf_parakeet_saved")
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "hf_parakeet_saved")

        plugin.clearHuggingFaceToken()
        XCTAssertNil(plugin.huggingFaceToken)
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "")
    }

    func testValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = makePlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_parakeet_test") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"name":"typewhisper","type":"user"}"#.utf8)
            return (data, response)
        }

        XCTAssertTrue(isValid)
        let maybeRequest = await requestRecorder.get()
        let request = try XCTUnwrap(maybeRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_parakeet_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testAppliesStoredHuggingFaceTokenToEnvironment() throws {
        let envKeys = [
            "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN",
            "HUGGINGFACEHUB_API_TOKEN",
        ]
        let originalTokens = Dictionary(
            uniqueKeysWithValues: envKeys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            }
        )
        defer {
            for key in envKeys {
                if let originalToken = originalTokens[key] ?? nil {
                    setenv(key, originalToken, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.setHuggingFaceToken("hf_env_parakeet")

        plugin.applyHuggingFaceTokenToEnvironment()

        for key in envKeys {
            XCTAssertEqual(getenv(key).map { String(cString: $0) }, "hf_env_parakeet")
        }
    }
}
