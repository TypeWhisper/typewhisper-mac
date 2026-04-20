import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class PluginManifestValidationTests: XCTestCase {
    func testAllPluginManifestsDecodeAndDeclareCompatibility() throws {
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: TestSupport.repoRoot.appendingPathComponent("Plugins"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        .map { $0.appendingPathComponent("manifest.json") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertFalse(manifestURLs.isEmpty)

        let versionPattern = try NSRegularExpression(pattern: #"^\d+\.\d+(\.\d+)?$"#)

        for manifestURL in manifestURLs {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

            XCTAssertFalse(manifest.id.isEmpty, manifestURL.lastPathComponent)
            XCTAssertFalse(manifest.name.isEmpty, manifestURL.lastPathComponent)
            XCTAssertFalse(manifest.principalClass.isEmpty, manifestURL.lastPathComponent)
            XCTAssertNotNil(manifest.minHostVersion, manifestURL.lastPathComponent)
            XCTAssertEqual(
                manifest.sdkCompatibilityVersion,
                PluginSDKCompatibility.currentVersion,
                manifestURL.lastPathComponent
            )

            let range = NSRange(location: 0, length: manifest.version.utf16.count)
            XCTAssertEqual(versionPattern.firstMatch(in: manifest.version, range: range)?.range, range, manifest.version)
        }
    }

    func testAppleSiliconOnlyPluginsDeclareArm64Compatibility() throws {
        let manifestPaths = [
            "Plugins/WhisperKitPlugin/manifest.json",
            "Plugins/ParakeetPlugin/manifest.json",
            "Plugins/GranitePlugin/manifest.json",
            "Plugins/Gemma4Plugin/manifest.json",
            "Plugins/Qwen3Plugin/manifest.json",
            "Plugins/VoxtralPlugin/manifest.json",
        ]

        for relativePath in manifestPaths {
            let manifestURL = TestSupport.repoRoot.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            XCTAssertEqual(manifest.supportedArchitectures, ["arm64"], relativePath)
        }
    }
}

@MainActor
final class Gemma4PluginModelPolicyTests: XCTestCase {
    private actor RequestRecorder {
        private var request: URLRequest?

        func set(_ request: URLRequest) {
            self.request = request
        }

        func get() -> URLRequest? {
            request
        }
    }

    private final class MockEventBus: EventBusProtocol {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var defaults: [String: Any]
        private var secrets: [String: String]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []
        private(set) var capabilitiesChangedCount = 0
        private(set) var streamingDisplayActiveValues: [Bool] = []

        init(
            pluginDataDirectory: URL,
            defaults: [String: Any] = [:],
            secrets: [String: String] = [:]
        ) {
            self.pluginDataDirectory = pluginDataDirectory
            self.defaults = defaults
            self.secrets = secrets
        }

        func storeSecret(key: String, value: String) throws { secrets[key] = value }
        func loadSecret(key: String) -> String? { secrets[key] }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() { capabilitiesChangedCount += 1 }
        func setStreamingDisplayActive(_ active: Bool) { streamingDisplayActiveValues.append(active) }
    }

    func testGemma4SupportedModelsRemainTheRecommendedDenseVariants() {
        XCTAssertEqual(
            Gemma4Plugin.supportedModelDefinitions.map(\.id),
            ["gemma-4-e2b-it-4bit", "gemma-4-e4b-it-4bit"]
        )
    }

    func testGemma4ExperimentalModelsExposeWarnings() {
        let experimentalModels = Gemma4Plugin.availableModels.filter { !$0.isSupported }

        XCTAssertEqual(
            experimentalModels.map(\.id),
            ["gemma-4-e4b-it-8bit", "gemma-4-26b-a4b-it-4bit"]
        )
        XCTAssertTrue(experimentalModels.allSatisfy { ($0.experimentalWarning ?? "").isEmpty == false })
    }

    func testGemma4ActivationPreservesExperimentalSelectedModel() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: ["selectedLLMModel": "gemma-4-26b-a4b-it-4bit"]
        )
        let plugin = Gemma4Plugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedLLMModelId, "gemma-4-26b-a4b-it-4bit")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gemma-4-26b-a4b-it-4bit")
    }

    func testGemma4ActivationKeepsExperimentalLoadedModelForManualRestore() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: [
                "selectedLLMModel": "gemma-4-e2b-it-4bit",
                "loadedModel": "gemma-4-26b-a4b-it-4bit"
            ]
        )
        let plugin = Gemma4Plugin()

        plugin.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "gemma-4-26b-a4b-it-4bit")
        XCTAssertEqual(plugin.modelState, .notLoaded)
    }

    func testGemma4CancelModelLoadResetsProgressAndState() throws {
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))

        plugin.beginModelLoad(for: model, isAlreadyDownloaded: false)
        plugin.cancelModelLoad()

        XCTAssertEqual(plugin.modelState, .notLoaded)
        XCTAssertEqual(plugin.currentDownloadProgress, 0)
        XCTAssertEqual(plugin.selectedLLMModelId, model.id)
    }

    func testGemma4UnsupportedModelTypeErrorsUseFriendlyMessage() throws {
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-26b-a4b-it-4bit"))
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model type gemma4 not supported"])

        let message = Gemma4Plugin.userFacingLoadErrorMessage(for: error, modelDef: model)

        XCTAssertEqual(
            message,
            "Gemma 4 26B-A4B (4-bit, MoE) is experimental in this TypeWhisper release and may still fail to load. Recommended models: Gemma 4 E2B (4-bit), Gemma 4 E4B (4-bit)."
        )
    }

    func testGemma4TimeoutErrorsSuggestRetryAndOptionalHuggingFaceToken() throws {
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let error = URLError(.timedOut)

        let message = Gemma4Plugin.userFacingLoadErrorMessage(for: error, modelDef: model)

        XCTAssertEqual(
            message,
            "Download timed out while fetching Gemma 4 from Hugging Face. Please retry. Adding an optional HuggingFace token in this plugin can also increase download rate limits."
        )
    }

    func testGemma4ValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = Gemma4Plugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_test_123") { request in
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_test_123")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testGemma4RejectsInvalidHuggingFaceTokenResponses() async {
        let plugin = Gemma4Plugin()

        let isValid = await plugin.validateHuggingFaceToken("hf_invalid") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        XCTAssertFalse(isValid)
    }

    func testGemma4UsesTemperatureControllableProviderPath() {
        let plugin: any LLMProviderPlugin = Gemma4Plugin()

        XCTAssertTrue(plugin is any LLMTemperatureControllableProvider)
    }

    func testGemma4PromptPrefillStepSizeIsReducedForLargerModels() {
        XCTAssertEqual(Gemma4Plugin.promptPrefillStepSize(for: "gemma-4-e2b-it-4bit"), 256)
        XCTAssertEqual(Gemma4Plugin.promptPrefillStepSize(for: "gemma-4-e4b-it-4bit"), 128)
        XCTAssertEqual(Gemma4Plugin.promptPrefillStepSize(for: "gemma-4-e4b-it-8bit"), 128)
        XCTAssertEqual(Gemma4Plugin.promptPrefillStepSize(for: "gemma-4-26b-a4b-it-4bit"), 64)
        XCTAssertEqual(Gemma4Plugin.promptPrefillStepSize(for: nil), 128)
    }

    func testQwen3ValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = Qwen3Plugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_qwen3_test") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"name":"typewhisper","auth":{"type":"access_token"}}"#.utf8)
            return (data, response)
        }

        XCTAssertTrue(isValid)
        let maybeRequest = await requestRecorder.get()
        let request = try XCTUnwrap(maybeRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_qwen3_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testQwen3RejectsInvalidHuggingFaceTokenResponses() async {
        let plugin = Qwen3Plugin()

        let isValid = await plugin.validateHuggingFaceToken("hf_invalid") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        XCTAssertFalse(isValid)
    }

    func testVoxtralValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = VoxtralPlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_voxtral_test") { request in
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_voxtral_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testVoxtralRejectsInvalidHuggingFaceTokenResponses() async {
        let plugin = VoxtralPlugin()

        let isValid = await plugin.validateHuggingFaceToken("hf_invalid") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        XCTAssertFalse(isValid)
    }

    func testGraniteValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = GranitePlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_granite_test") { request in
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_granite_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testGraniteRejectsInvalidHuggingFaceTokenResponses() async {
        let plugin = GranitePlugin()

        let isValid = await plugin.validateHuggingFaceToken("hf_invalid") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        XCTAssertFalse(isValid)
    }

    func testWhisperKitValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = WhisperKitPlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_whisperkit_test") { request in
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_whisperkit_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testWhisperKitRejectsInvalidHuggingFaceTokenResponses() async {
        let plugin = WhisperKitPlugin()

        let isValid = await plugin.validateHuggingFaceToken("hf_invalid") { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        XCTAssertFalse(isValid)
    }

    func testWhisperKitActivationDoesNotAutoRestorePersistedLoadedModel() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: [
                "selectedModel": "openai_whisper-tiny",
                "loadedModel": "openai_whisper-tiny",
            ]
        )
        let plugin = WhisperKitPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertFalse(plugin.isConfigured)
    }
}

@MainActor
final class PluginManagerLoadOrderTests: XCTestCase {
    func testSortedPluginBundleURLsPrioritizeEnabledBundlesBeforeDisabledOnes() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let pluginsDirectory = manager.pluginsDirectory
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        let disabledVoxtral = try makePluginBundle(
            at: pluginsDirectory,
            bundleName: "VoxtralPlugin.bundle",
            pluginId: "com.typewhisper.voxtral",
            pluginName: "Voxtral"
        )
        let enabledGemma = try makePluginBundle(
            at: pluginsDirectory,
            bundleName: "Gemma4Plugin.bundle",
            pluginId: "com.typewhisper.gemma4",
            pluginName: "Gemma 4"
        )
        let enabledParakeet = try makePluginBundle(
            at: pluginsDirectory,
            bundleName: "ParakeetPlugin.bundle",
            pluginId: "com.typewhisper.parakeet",
            pluginName: "Parakeet"
        )

        let voxtralKey = "plugin.com.typewhisper.voxtral.enabled"
        let gemmaKey = "plugin.com.typewhisper.gemma4.enabled"
        let parakeetKey = "plugin.com.typewhisper.parakeet.enabled"

        let defaults = UserDefaults.standard
        let originalVoxtral = defaults.object(forKey: voxtralKey)
        let originalGemma = defaults.object(forKey: gemmaKey)
        let originalParakeet = defaults.object(forKey: parakeetKey)
        defer {
            restore(defaults, key: voxtralKey, value: originalVoxtral)
            restore(defaults, key: gemmaKey, value: originalGemma)
            restore(defaults, key: parakeetKey, value: originalParakeet)
        }

        defaults.set(false, forKey: voxtralKey)
        defaults.set(true, forKey: gemmaKey)
        defaults.set(true, forKey: parakeetKey)

        let sorted = manager.sortedPluginBundleURLs(
            [disabledVoxtral, enabledParakeet, enabledGemma],
            isBundledSource: false
        )

        XCTAssertEqual(
            sorted.map(\.lastPathComponent),
            ["Gemma4Plugin.bundle", "ParakeetPlugin.bundle", "VoxtralPlugin.bundle"]
        )
    }

    func testScanAndLoadPluginsRegistersDisabledBundleWithoutLoadingRuntime() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let pluginsDirectory = manager.pluginsDirectory
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        _ = try makePluginBundle(
            at: pluginsDirectory,
            bundleName: "DisabledLLMPlugin.bundle",
            pluginId: "com.typewhisper.disabled-llm",
            pluginName: "Disabled LLM",
            principalClass: "MissingPluginClass",
            category: "llm"
        )

        let enabledKey = "plugin.com.typewhisper.disabled-llm.enabled"
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: enabledKey)
        defer { restore(defaults, key: enabledKey, value: originalValue) }
        defaults.set(false, forKey: enabledKey)

        manager.scanAndLoadPlugins()

        let plugin = try XCTUnwrap(manager.loadedPlugins.first { $0.manifest.id == "com.typewhisper.disabled-llm" })
        XCTAssertFalse(plugin.isEnabled)
        XCTAssertFalse(plugin.bundle.isLoaded)
        XCTAssertEqual(plugin.manifest.category, "llm")
    }

    private func makePluginBundle(
        at directory: URL,
        bundleName: String,
        pluginId: String,
        pluginName: String,
        sdkCompatibilityVersion: String? = PluginSDKCompatibility.currentVersion,
        principalClass: String = "NSObject",
        category: String? = nil
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let manifest = PluginManifest(
            id: pluginId,
            name: pluginName,
            version: "1.0.0",
            sdkCompatibilityVersion: sdkCompatibilityVersion,
            principalClass: principalClass,
            category: category
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: resourcesURL.appendingPathComponent("manifest.json"))
        return bundleURL
    }

    private func restore(_ defaults: UserDefaults, key: String, value: Any?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class Qwen3PluginContextFormattingTests: XCTestCase {
    func testQwen3ContextFormatterReturnsEmptyStringForNilPrompt() throws {
        XCTAssertEqual(Qwen3ContextBiasFormatter.format(prompt: nil), "")
    }

    func testQwen3ContextFormatterWrapsSingleTerm() throws {
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: "Qwen3"),
            "Technical terms: Qwen3."
        )
    }

    func testQwen3ContextFormatterWrapsMultipleTermsAsCommaSeparatedSentence() throws {
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: "Qwen3, MLX, LoRA"),
            "Technical terms: Qwen3, MLX, LoRA."
        )
    }

    func testQwen3ContextFormatterPreservesNormalizedAndDeduplicatedTerms() throws {
        let prompt = PluginDictionaryTerms.prompt(from: [" Kubernetes ", "MLX", "mlx", "TypeWhisper"])
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: prompt),
            "Technical terms: Kubernetes, MLX, TypeWhisper."
        )
    }
}

@MainActor
final class PluginArchitectureCompatibilityTests: XCTestCase {
    private final class MockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.compatible" }
        static var pluginName: String { "Mock Compatible" }

        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "mock-compatible" }
        var providerDisplayName: String { "Mock Compatible" }
        var isConfigured: Bool { true }
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["en"] }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        func selectModel(_ modelId: String) {}
        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "ok", detectedLanguage: language)
        }
    }

    override func tearDown() {
        RuntimeArchitecture.overrideCurrent = nil
        super.tearDown()
    }

    func testPluginManagerRejectsArm64OnlyManifestOnIntel() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.arm64-only",
            name: "ARM64 Only",
            version: "1.0.0",
            supportedArchitectures: ["arm64"],
            principalClass: "MockPlugin"
        )

        RuntimeArchitecture.overrideCurrent = "x86_64"
        XCTAssertFalse(manager.isManifestCompatible(manifest))

        RuntimeArchitecture.overrideCurrent = "arm64"
        XCTAssertTrue(manager.isManifestCompatible(manifest))
    }

    func testExternalPluginsRequireExactSDKCompatibilityVersionWhileBundledPluginsAreExempt() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let matchingManifest = PluginManifest(
            id: "com.typewhisper.mock.sdk-match",
            name: "SDK Match",
            version: "1.0.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            principalClass: "MockPlugin"
        )
        let missingManifest = PluginManifest(
            id: "com.typewhisper.mock.sdk-missing",
            name: "SDK Missing",
            version: "1.0.0",
            principalClass: "MockPlugin"
        )
        let mismatchedManifest = PluginManifest(
            id: "com.typewhisper.mock.sdk-mismatch",
            name: "SDK Mismatch",
            version: "1.0.0",
            sdkCompatibilityVersion: "v999",
            principalClass: "MockPlugin"
        )

        XCTAssertTrue(manager.isManifestSDKCompatible(matchingManifest, isBundled: false))
        XCTAssertFalse(manager.isManifestSDKCompatible(missingManifest, isBundled: false))
        XCTAssertFalse(manager.isManifestSDKCompatible(mismatchedManifest, isBundled: false))
        XCTAssertTrue(manager.isManifestSDKCompatible(missingManifest, isBundled: true))
    }

    func testExternalBundleNoticeShowsBundledFallbackWhenLegacyBundleIsSkipped() throws {
        let builtInURL = (Bundle.main.builtInPlugInsURL ?? URL(fileURLWithPath: "/Applications/TypeWhisper.app/Contents/PlugIns"))
            .appendingPathComponent("Mock.bundle")
        let bundledPlugin = LoadedPlugin(
            manifest: PluginManifest(
                id: "com.typewhisper.mock.sdk-missing",
                name: "Bundled Replacement",
                version: "1.3.0",
                principalClass: "MockTranscriptionPlugin"
            ),
            instance: MockTranscriptionPlugin(),
            bundle: Bundle.main,
            sourceURL: builtInURL,
            isEnabled: true
        )

        let notice = PluginManager.externalBundleNotice(
            loadedPlugin: bundledPlugin,
            registryPlugin: nil,
            incompatibleExternalBundle: IncompatibleExternalBundle(
                pluginId: "com.typewhisper.mock.sdk-missing",
                pluginName: "Legacy External",
                version: "1.2.2",
                bundleURL: URL(fileURLWithPath: "/tmp/TypeWhisper/Plugins/Legacy.bundle"),
                reason: .sdkCompatibility(
                    expected: PluginSDKCompatibility.currentVersion,
                    actual: nil
                )
            )
        )

        XCTAssertEqual(notice, .bundledFallbackActive(version: "1.2.2"))
    }

    func testExternalBundleNoticeEscalatesToBoundaryUpgradeWhenMarketplaceReplacementExists() {
        let notice = PluginManager.externalBundleNotice(
            loadedPlugin: nil,
            registryPlugin: RegistryPlugin(
                id: "com.typewhisper.mock.sdk-missing",
                name: "Marketplace Replacement",
                version: "1.3.1",
                minHostVersion: "1.3.0",
                sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                minOSVersion: nil,
                supportedArchitectures: nil,
                author: "TypeWhisper",
                description: "Replacement",
                category: "utility",
                size: 1,
                downloadURL: "https://example.com/replacement.zip",
                iconSystemName: nil,
                requiresAPIKey: nil,
                descriptions: nil,
                downloadCount: nil
            ),
            incompatibleExternalBundle: IncompatibleExternalBundle(
                pluginId: "com.typewhisper.mock.sdk-missing",
                pluginName: "Legacy External",
                version: "1.2.2",
                bundleURL: URL(fileURLWithPath: "/tmp/TypeWhisper/Plugins/Legacy.bundle"),
                reason: .sdkCompatibility(
                    expected: PluginSDKCompatibility.currentVersion,
                    actual: nil
                )
            )
        )

        XCTAssertEqual(
            notice,
            .boundaryUpgradeRequired(installedVersion: "1.2.2", availableVersion: "1.3.1")
        )
    }

    func testRegistryPluginRejectsArm64OnlyEntryOnIntel() {
        let plugin = RegistryPlugin(
            id: "com.typewhisper.mock.arm64-only",
            name: "ARM64 Only",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            minOSVersion: "14.0",
            supportedArchitectures: ["arm64"],
            author: "TypeWhisper",
            description: "Test plugin",
            category: "transcription",
            size: 1,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            descriptions: nil,
            downloadCount: nil
        )

        RuntimeArchitecture.overrideCurrent = "x86_64"
        XCTAssertFalse(plugin.isCompatibleWithCurrentEnvironment)

        RuntimeArchitecture.overrideCurrent = "arm64"
        XCTAssertTrue(plugin.isCompatibleWithCurrentEnvironment)
    }

    func testModelManagerFallsBackWhenStoredProviderIsUnavailable() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.set("whisper", forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.compatible",
                    name: "Mock Compatible",
                    version: "1.0.0",
                    principalClass: "MockTranscriptionPlugin"
                ),
                instance: MockTranscriptionPlugin(),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.restoreProviderSelection()

        XCTAssertEqual(modelManager.selectedProviderId, "mock-compatible")
    }

    func testWatchFolderSelectionClearsMissingSavedEngine() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let selectedEngineKey = UserDefaultsKeys.watchFolderEngine
        let selectedModelKey = UserDefaultsKeys.watchFolderModel
        let originalEngine = UserDefaults.standard.object(forKey: selectedEngineKey)
        let originalModel = UserDefaults.standard.object(forKey: selectedModelKey)
        UserDefaults.standard.set("whisper", forKey: selectedEngineKey)
        UserDefaults.standard.set("openai_whisper-large-v3_turbo", forKey: selectedModelKey)
        defer {
            if let originalEngine {
                UserDefaults.standard.set(originalEngine, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: selectedModelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedModelKey)
            }
        }

        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.compatible",
                    name: "Mock Compatible",
                    version: "1.0.0",
                    principalClass: "MockTranscriptionPlugin"
                ),
                instance: MockTranscriptionPlugin(),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let watchFolderService = WatchFolderService(
            audioFileService: AudioFileService(),
            modelManagerService: ModelManagerService()
        )
        let viewModel = WatchFolderViewModel(
            watchFolderService: watchFolderService,
            modelManager: ModelManagerService()
        )
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
    }
}

@MainActor
final class PluginRegistryDestinationTests: XCTestCase {
    func testFreshInstallTargetsPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: nil,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
    }

    func testExistingBundleInsidePluginsDirectoryKeepsItsPath() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let existingURL = pluginsDirectory.appendingPathComponent("CustomParakeet.bundle")

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: existingURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, existingURL)
    }

    func testTemporaryLoadedBundleIsRehomedIntoPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let temporaryURL = URL(fileURLWithPath: "/tmp/typewhisper-install/extracted/ParakeetPlugin.bundle", isDirectory: true)

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: temporaryURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
    }

    func testBuiltInBundleIsRehomedIntoPluginsDirectory() {
        let pluginsDirectory = URL(fileURLWithPath: "/tmp/TypeWhisper-Dev/Plugins", isDirectory: true)
        let builtInPluginsURL = URL(fileURLWithPath: "/Applications/TypeWhisper.app/Contents/PlugIns", isDirectory: true)
        let builtInURL = builtInPluginsURL.appendingPathComponent("ParakeetPlugin.bundle")

        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: builtInURL,
            builtInPluginsURL: builtInPluginsURL,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "ParakeetPlugin.bundle"
        )

        XCTAssertEqual(destination, pluginsDirectory.appendingPathComponent("ParakeetPlugin.bundle"))
    }
}

final class OpenAIPluginTokenParameterTests: XCTestCase {
    func testLegacyOpenAIModelsKeepMaxTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "gpt-4o"), "max_tokens")
    }

    func testGPT5ModelsUseMaxCompletionTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "gpt-5.4"), "max_completion_tokens")
    }

    func testO4ModelsUseMaxCompletionTokens() {
        XCTAssertEqual(OpenAIPlugin.outputTokenParameter(for: "o4-mini"), "max_completion_tokens")
    }

    func testGPT5ChatCompletionsOmitTemperatureWhenReasoningIsEnabled() {
        XCTAssertNil(OpenAIPlugin.chatCompletionTemperature(for: "gpt-5.4", reasoningEffort: "medium"))
    }

    func testLegacyChatCompletionsKeepTemperature() {
        XCTAssertEqual(OpenAIPlugin.chatCompletionTemperature(for: "gpt-4o", reasoningEffort: nil), 0.3)
    }
}
