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

    private actor VocabularyFetchRecorder {
        private var requests: [(url: URL, description: String)] = []
        private let data: Data?
        private let error: Error?

        init(data: Data) {
            self.data = data
            self.error = nil
        }

        init(error: Error) {
            self.data = nil
            self.error = error
        }

        func fetch(url: URL, description: String) async throws -> Data {
            requests.append((url: url, description: description))
            if let data {
                return data
            }
            throw error ?? URLError(.unknown)
        }

        func requestCount() -> Int {
            requests.count
        }

        func firstRequest() -> (url: URL, description: String)? {
            requests.first
        }
    }

    private func makePlugin(restoresModelOnActivate: Bool = false) -> ParakeetPlugin {
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = restoresModelOnActivate
        return plugin
    }

    private func makeTemporaryDirectory(prefix: String = "ParakeetPluginTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func testVocabularyAssetURLsMapToVersionRepositories() {
        XCTAssertEqual(
            ParakeetPlugin.vocabularyAssetURL(for: .v2).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/main/parakeet_vocab.json"
        )
        XCTAssertEqual(
            ParakeetPlugin.vocabularyAssetURL(for: .v3).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/parakeet_vocab.json"
        )
    }

    func testEnsureVocabularyAssetSkipsExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let existingData = Data(#"{"0":"existing"}"#.utf8)
        try existingData.write(to: targetURL)
        let recorder = VocabularyFetchRecorder(data: Data(#"{"0":"downloaded"}"#.utf8))
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(try Data(contentsOf: targetURL), existingData)
    }

    func testEnsureVocabularyAssetRepairsEmptyExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        try Data().write(to: targetURL)
        let downloadedData = Data(#"{"0":"downloaded"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testEnsureVocabularyAssetDownloadsMissingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"<blank>"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetPlugin.vocabularyAssetURL(for: .v3))
        XCTAssertEqual(request.description, "Parakeet TDT v3 vocabulary")
    }

    func testEnsureVocabularyAssetCreatesMissingTargetDirectory() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        let directory = parentDirectory.appendingPathComponent("missing-cache", isDirectory: true)
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"created-directory"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v2,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetPlugin.vocabularyAssetURL(for: .v2))
    }

    func testEnsureVocabularyAssetSurfacesFailedFetch() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let recorder = VocabularyFetchRecorder(
            error: NSError(
                domain: "ParakeetVocabularyAssetTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "network unavailable"]
            )
        )
        let plugin = makePlugin()

        do {
            try await plugin.ensureVocabularyAsset(
                for: .v2,
                targetDirectory: directory,
                fetcher: { url, description in
                    try await recorder.fetch(url: url, description: description)
                }
            )
            XCTFail("Expected vocabulary download to fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Failed to download Parakeet vocabulary file for Parakeet TDT v2"
                )
            )
            XCTAssertTrue(error.localizedDescription.contains("network unavailable"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
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

    func testAllowsTranscriptPreviewFallback() throws {
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = ParakeetPlugin()

        XCTAssertTrue(fallbackPolicy.allowsTranscriptPreviewFallback)
    }

    func testUsesBatchFallbackForLivePreview() throws {
        let plugin = ParakeetPlugin()
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = plugin

        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertTrue(fallbackPolicy.allowsTranscriptPreviewFallback)
        XCTAssertNil(plugin as? any LiveTranscriptionCapablePlugin)
    }

    func testSourceProgressMapsProgressFractionToAudioDuration() {
        let progress = ParakeetPlugin.sourceProgress(fromFraction: 0.25, totalDuration: 240)

        XCTAssertEqual(progress?.processedDuration, 60)
        XCTAssertEqual(progress?.totalDuration, 240)
        XCTAssertEqual(progress?.fractionCompleted, 0.25)
    }

    func testSourceProgressClampsAndRejectsInvalidDurations() {
        XCTAssertEqual(
            ParakeetPlugin.sourceProgress(fromFraction: 1.5, totalDuration: 10)?.processedDuration,
            10
        )
        XCTAssertEqual(
            ParakeetPlugin.sourceProgress(fromFraction: -0.5, totalDuration: 10)?.processedDuration,
            0
        )
        XCTAssertNil(ParakeetPlugin.sourceProgress(fromFraction: .nan, totalDuration: 10))
        XCTAssertNil(ParakeetPlugin.sourceProgress(fromFraction: 0.5, totalDuration: 0))
    }

    func testSourceProgressObservationOnlyStartsForFluidAudioProgressRange() {
        XCTAssertFalse(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 160_000))
        XCTAssertFalse(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 240_000))
        XCTAssertTrue(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 240_001))
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

    func testVocabularyHintsPreferStructuredHintsOverPrompt() throws {
        let hints = ParakeetPlugin.vocabularyHints(
            prompt: "PromptTerm",
            dictionaryTermHints: [
                PluginDictionaryTermHint(text: " Caivex ", ctcMinSimilarity: 0.5),
                PluginDictionaryTermHint(text: "caivex", ctcMinSimilarity: 0.8),
                PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            ]
        )

        XCTAssertEqual(hints, [
            PluginDictionaryTermHint(text: "Caivex", ctcMinSimilarity: 0.5),
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])
    }

    func testVocabularyHintsFallbackToPromptAndEncodeThresholdSignature() throws {
        XCTAssertEqual(
            ParakeetPlugin.vocabularyHints(prompt: " Alpha, Beta, alpha ", dictionaryTermHints: []),
            [
                PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
                PluginDictionaryTermHint(text: "Beta", ctcMinSimilarity: nil),
            ]
        )

        let signature = ParakeetPlugin.vocabularySignature(from: [
            PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Beta", ctcMinSimilarity: 0.65),
        ])

        XCTAssertEqual(signature, "Alpha|auto\u{1F}Beta|0.6500")
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
