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

            let range = NSRange(location: 0, length: manifest.version.utf16.count)
            XCTAssertEqual(versionPattern.firstMatch(in: manifest.version, range: range)?.range, range, manifest.version)
        }
    }

    func testAppleSiliconOnlyPluginsDeclareArm64Compatibility() throws {
        let manifestPaths = [
            "Plugins/WhisperKitPlugin/manifest.json",
            "Plugins/ParakeetPlugin/manifest.json",
            "Plugins/GranitePlugin/manifest.json",
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

    func testRegistryPluginRejectsArm64OnlyEntryOnIntel() {
        let plugin = RegistryPlugin(
            id: "com.typewhisper.mock.arm64-only",
            name: "ARM64 Only",
            version: "1.0.0",
            minHostVersion: "1.0.0",
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
