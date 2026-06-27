import Combine
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class PluginManifestValidationTests: XCTestCase {
    func testAllPluginManifestsDecodeAndDeclareCompatibility() throws {
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins"),
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

    func testOptionalPluginManifestLinksUseAbsoluteHTTPURLs() throws {
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        .map { $0.appendingPathComponent("manifest.json") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

        XCTAssertFalse(manifestURLs.isEmpty)

        for manifestURL in manifestURLs {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

            for urlString in [manifest.detailsURL, manifest.homepageURL].compactMap({ $0 }) {
                let components = URLComponents(string: urlString)
                let scheme = components?.scheme?.lowercased()
                XCTAssertTrue(
                    scheme == "https" || scheme == "http",
                    "\(manifestURL.lastPathComponent): \(urlString)"
                )
                XCTAssertNotNil(components?.host, "\(manifestURL.lastPathComponent): \(urlString)")
            }

            for urlString in [manifest.iconURL, manifest.iconDarkURL].compactMap({ $0 }) {
                let components = URLComponents(string: urlString)
                XCTAssertEqual(components?.scheme?.lowercased(), "https", "\(manifestURL.lastPathComponent): \(urlString)")
                XCTAssertNotNil(components?.host, "\(manifestURL.lastPathComponent): \(urlString)")
            }
        }
    }

    func testAppleSiliconOnlyPluginsDeclareArm64Compatibility() throws {
        let manifestPaths = [
            "TypeWhisperPluginSDK/Plugins/WhisperKitPlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/ParakeetPlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/GranitePlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/Gemma4Plugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/VoxtralPlugin/manifest.json",
        ]

        for relativePath in manifestPaths {
            let manifestURL = TestSupport.repoRoot.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            XCTAssertEqual(manifest.supportedArchitectures, ["arm64"], relativePath)
        }
    }

    func testSourceFootageProgressPluginsDeclareCapability() throws {
        let manifestPaths = [
            "TypeWhisperPluginSDK/Plugins/WhisperKitPlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/ParakeetPlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/SonioxPlugin/manifest.json",
        ]

        for relativePath in manifestPaths {
            let manifestURL = TestSupport.repoRoot.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            XCTAssertTrue(manifest.supportsCapability(.sourceFootageProgress), relativePath)
            XCTAssertEqual(manifest.minHostVersion, "1.5.0", relativePath)
        }
    }

    func testDownloadedModelManagingPluginReleasesRequireHost14() throws {
        let manifestPaths = [
            "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/VoxtralPlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/GranitePlugin/manifest.json",
            "TypeWhisperPluginSDK/Plugins/SupertonicPlugin/manifest.json",
        ]

        for relativePath in manifestPaths {
            let manifestURL = TestSupport.repoRoot.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
            XCTAssertEqual(manifest.minHostVersion, "1.4.0", relativePath)
        }
    }

    func testGemma4PluginReleaseRequiresHost15() throws {
        let manifestURL = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/Gemma4Plugin/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.minHostVersion, "1.5.0")
    }

    func testOpenAIPluginManifestDeclaresCloudHostingWithoutAPIKeyRequirement() throws {
        let manifestURL = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/OpenAIPlugin/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.minHostVersion, "1.5.0")
        XCTAssertEqual(manifest.hosting, .cloud)
        XCTAssertEqual(manifest.requiresAPIKey, false)
        XCTAssertEqual(manifest.resolvedHosting, .cloud)
        XCTAssertEqual(manifest.resolvedCategoryIdentifiers, ["transcription", "llm", "tts"])
    }

    func testGroqPluginReleaseRequiresHost15() throws {
        let manifestURL = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/GroqPlugin/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.version, "1.0.16")
        XCTAssertEqual(manifest.minHostVersion, "1.5.0")
        XCTAssertEqual(manifest.sdkCompatibilityVersion, PluginSDKCompatibility.currentVersion)
    }

    func testQwen3UnsupportedLanguageSelectionFallsBackToAuto() {
        XCTAssertEqual(
            LanguageSelection.exact("uk").normalizedForSupportedLanguages(Qwen3Plugin.qwenSupportedLanguageCodes),
            .auto
        )
        XCTAssertEqual(
            LanguageSelection.hints(["fr", "uk"]).normalizedForSupportedLanguages(Qwen3Plugin.qwenSupportedLanguageCodes),
            .exact("fr")
        )
    }

    @MainActor
    func testNotifyPluginStateChangedIncrementsReadinessRevisionAndNotifiesObservers() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let initialRevision = manager.readinessRevision
        let notification = expectation(description: "plugin manager publishes readiness change")

        let cancellable = manager.objectWillChange.sink {
            notification.fulfill()
        }

        manager.notifyPluginStateChanged()

        XCTAssertEqual(manager.readinessRevision, initialRevision + 1)
        wait(for: [notification], timeout: 1)
        withExtendedLifetime(cancellable) {}
    }
}

@MainActor
final class PluginDownloadedModelManagementTests: XCTestCase {
    private final class MockDownloadedModelPlugin: NSObject, TypeWhisperPlugin, PluginDownloadedModelManaging, PluginSettingsActivityReporting, @unchecked Sendable {
        static let pluginId = "com.typewhisper.tests.downloaded-models"
        static let pluginName = "Downloaded Models Test Plugin"

        var downloadedModels: [PluginModelInfo]
        var currentSettingsActivity: PluginSettingsActivity?
        var shouldFailDeletion = false
        var shouldSuspendDeletion = false
        var deletionDidStart: (() -> Void)?
        private var deletionResume: CheckedContinuation<Void, Never>?
        private(set) var deletedModelIds: [String] = []
        private(set) var didDeactivate = false

        required override init() {
            self.downloadedModels = []
            super.init()
        }

        init(downloadedModels: [PluginModelInfo]) {
            self.downloadedModels = downloadedModels
            super.init()
        }

        func activate(host: HostServices) {}

        func deactivate() {
            didDeactivate = true
        }

        func deleteDownloadedModel(_ modelId: String) async throws {
            if shouldFailDeletion {
                throw NSError(
                    domain: "PluginDownloadedModelManagementTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Deletion failed"]
                )
            }

            deletionDidStart?()
            if shouldSuspendDeletion {
                await withCheckedContinuation { continuation in
                    deletionResume = continuation
                }
            }

            deletedModelIds.append(modelId)
            downloadedModels.removeAll { $0.id == modelId }
        }

        func resumeDeletion() {
            deletionResume?.resume()
            deletionResume = nil
        }
    }

    func testDeletingOneOfMultipleDownloadedModelsKeepsPluginEnabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginDownloadedModels")
        defer { TestSupport.remove(appSupportDirectory) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let plugin = MockDownloadedModelPlugin(downloadedModels: [
            PluginModelInfo(id: "small", displayName: "Small", downloaded: true),
            PluginModelInfo(id: "large", displayName: "Large", downloaded: true),
        ])
        manager.loadedPlugins = [
            try makeLoadedPlugin(
                plugin: plugin,
                pluginId: "com.typewhisper.tests.downloaded.multiple",
                directory: appSupportDirectory
            )
        ]

        let initialRevision = manager.readinessRevision

        try await manager.deleteDownloadedModel(
            pluginId: "com.typewhisper.tests.downloaded.multiple",
            modelId: "small"
        )

        XCTAssertEqual(plugin.deletedModelIds, ["small"])
        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["large"])
        XCTAssertEqual(manager.loadedPlugins.first?.isEnabled, true)
        XCTAssertFalse(plugin.didDeactivate)
        XCTAssertEqual(manager.readinessRevision, initialRevision + 1)
    }

    func testDeletingLastDownloadedModelDisablesPlugin() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginDownloadedModels")
        defer { TestSupport.remove(appSupportDirectory) }

        let pluginId = "com.typewhisper.tests.downloaded.single"
        let defaultsKey = "plugin.\(pluginId).enabled"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer { restoreDefault(key: defaultsKey, value: originalValue) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let plugin = MockDownloadedModelPlugin(downloadedModels: [
            PluginModelInfo(id: "only", displayName: "Only", downloaded: true)
        ])
        manager.loadedPlugins = [
            try makeLoadedPlugin(plugin: plugin, pluginId: pluginId, directory: appSupportDirectory)
        ]

        try await manager.deleteDownloadedModel(pluginId: pluginId, modelId: "only")

        XCTAssertEqual(plugin.deletedModelIds, ["only"])
        XCTAssertTrue(plugin.downloadedModels.isEmpty)
        XCTAssertEqual(manager.loadedPlugins.first?.isEnabled, false)
        XCTAssertTrue(plugin.didDeactivate)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: defaultsKey), false)
    }

    func testDeletionFailureDoesNotDisablePluginOrDropModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginDownloadedModels")
        defer { TestSupport.remove(appSupportDirectory) }

        let pluginId = "com.typewhisper.tests.downloaded.failure"
        let defaultsKey = "plugin.\(pluginId).enabled"
        let originalValue = UserDefaults.standard.object(forKey: defaultsKey)
        defer { restoreDefault(key: defaultsKey, value: originalValue) }

        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let plugin = MockDownloadedModelPlugin(downloadedModels: [
            PluginModelInfo(id: "only", displayName: "Only", downloaded: true)
        ])
        plugin.shouldFailDeletion = true
        manager.loadedPlugins = [
            try makeLoadedPlugin(plugin: plugin, pluginId: pluginId, directory: appSupportDirectory)
        ]

        do {
            try await manager.deleteDownloadedModel(pluginId: pluginId, modelId: "only")
            XCTFail("Expected deletion to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Deletion failed")
        }

        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["only"])
        XCTAssertEqual(manager.loadedPlugins.first?.isEnabled, true)
        XCTAssertFalse(plugin.didDeactivate)
    }

    func testDeletionDuringPluginModelActivityThrowsBusyAndLeavesModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginDownloadedModels")
        defer { TestSupport.remove(appSupportDirectory) }

        let pluginId = "com.typewhisper.tests.downloaded.busy"
        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let plugin = MockDownloadedModelPlugin(downloadedModels: [
            PluginModelInfo(id: "only", displayName: "Only", downloaded: true)
        ])
        plugin.currentSettingsActivity = PluginSettingsActivity(message: "Downloading model", progress: 0.5)
        manager.loadedPlugins = [
            try makeLoadedPlugin(plugin: plugin, pluginId: pluginId, directory: appSupportDirectory)
        ]

        do {
            try await manager.deleteDownloadedModel(pluginId: pluginId, modelId: "only")
            XCTFail("Expected deletion to be blocked while the plugin reports activity")
        } catch PluginModelManagementError.pluginBusy(let name) {
            XCTAssertEqual(name, "Downloaded Models Test Plugin")
        } catch {
            XCTFail("Expected pluginBusy, got \(error)")
        }

        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["only"])
        XCTAssertTrue(plugin.deletedModelIds.isEmpty)
        XCTAssertEqual(manager.loadedPlugins.first?.isEnabled, true)
        XCTAssertFalse(plugin.didDeactivate)
    }

    func testConcurrentDeletionForSamePluginThrowsBusy() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginDownloadedModels")
        defer { TestSupport.remove(appSupportDirectory) }

        let pluginId = "com.typewhisper.tests.downloaded.concurrent"
        let manager = PluginManager(appSupportDirectory: appSupportDirectory)
        let plugin = MockDownloadedModelPlugin(downloadedModels: [
            PluginModelInfo(id: "one", displayName: "One", downloaded: true),
            PluginModelInfo(id: "two", displayName: "Two", downloaded: true),
        ])
        plugin.shouldSuspendDeletion = true
        let deletionStarted = expectation(description: "first deletion started")
        plugin.deletionDidStart = {
            deletionStarted.fulfill()
        }
        manager.loadedPlugins = [
            try makeLoadedPlugin(plugin: plugin, pluginId: pluginId, directory: appSupportDirectory)
        ]

        let firstDeletion = Task {
            try await manager.deleteDownloadedModel(pluginId: pluginId, modelId: "one")
        }
        await fulfillment(of: [deletionStarted], timeout: 1)

        do {
            try await manager.deleteDownloadedModel(pluginId: pluginId, modelId: "two")
            XCTFail("Expected concurrent deletion to be blocked")
        } catch PluginModelManagementError.pluginBusy(let name) {
            XCTAssertEqual(name, "Downloaded Models Test Plugin")
        } catch {
            XCTFail("Expected pluginBusy, got \(error)")
        }

        plugin.resumeDeletion()
        try await firstDeletion.value

        XCTAssertEqual(plugin.deletedModelIds, ["one"])
        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["two"])
        XCTAssertEqual(manager.loadedPlugins.first?.isEnabled, true)
        XCTAssertFalse(plugin.didDeactivate)
    }

    private func makeLoadedPlugin(
        plugin: MockDownloadedModelPlugin,
        pluginId: String,
        directory: URL
    ) throws -> LoadedPlugin {
        let bundleURL = directory.appendingPathComponent("\(pluginId).bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": pluginId,
            "CFBundleName": "Downloaded Models Test Plugin",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let manifest = PluginManifest(
            id: pluginId,
            name: "Downloaded Models Test Plugin",
            version: "1.0.0",
            principalClass: "MockDownloadedModelPlugin"
        )
        return LoadedPlugin(
            manifest: manifest,
            instance: plugin,
            bundle: bundle,
            sourceURL: bundleURL,
            isEnabled: true
        )
    }

    private func restoreDefault(key: String, value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
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

    func testGemma4RestoreClearsStaleLoadedModelWhenDownloadsAreDisabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let modelDirectory = gemmaModelDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writePartialGemmaCache(at: modelDirectory)
        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: ["loadedModel": model.id]
        )
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)

        await plugin.restoreLoadedModel(allowDownloads: false)

        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
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

    func testGemma4DownloadActivityIsIndeterminateUntilVisibleProgress() throws {
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))

        plugin.beginModelLoad(for: model, isAlreadyDownloaded: false)

        let activity = try XCTUnwrap(plugin.currentSettingsActivity)
        XCTAssertEqual(activity.message, "Downloading model")
        XCTAssertNil(activity.progress)
        XCTAssertFalse(plugin.hasVisibleDownloadProgress)
    }

    func testGemma4DownloadActivityReportsVisibleProgress() throws {
        let plugin = Gemma4Plugin()
        let generation = plugin.startModelLoadTimeoutForTesting(modelName: "Gemma 4 E2B")

        plugin.recordModelLoadProgressForTesting(fraction: 0.5, generation: generation)

        let activity = try XCTUnwrap(plugin.currentSettingsActivity)
        XCTAssertEqual(activity.message, "Downloading model")
        XCTAssertEqual(activity.progress ?? 0, 0.39, accuracy: 0.001)
        XCTAssertTrue(plugin.hasVisibleDownloadProgress)
    }

    func testGemma4PartialCacheIsNotTreatedAsDownloaded() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let modelDirectory = gemmaModelDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writePartialGemmaCache(at: modelDirectory)

        plugin.activate(host: host)

        XCTAssertTrue(plugin.hasCachedModelFiles(model))
        XCTAssertFalse(plugin.isModelDownloaded(model))
        XCTAssertFalse(plugin.downloadedModels.contains { $0.id == model.id })
    }

    func testGemma4HubCacheOnlyIsNotDownloadedButCanBeRemoved() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let hubCacheDirectory = gemmaHubCacheDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writeHubGemmaCache(at: hubCacheDirectory)

        plugin.activate(host: host)

        XCTAssertTrue(plugin.hasCachedModelFiles(model))
        XCTAssertFalse(plugin.isModelDownloaded(model))
        XCTAssertFalse(plugin.downloadedModels.contains { $0.id == model.id })

        try await plugin.deleteDownloadedModel(model.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hubCacheDirectory.path))
        XCTAssertFalse(plugin.hasCachedModelFiles(model))
    }

    func testGemma4ValidMinimalCacheIsTreatedAsDownloaded() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e4b-it-4bit"))
        let modelDirectory = gemmaModelDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writeUsableGemmaCache(at: modelDirectory)

        plugin.activate(host: host)

        XCTAssertTrue(plugin.hasCachedModelFiles(model))
        XCTAssertTrue(plugin.isModelDownloaded(model))
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])
    }

    func testGemma4ModelLoadTimeoutSetsErrorAndResetsProgress() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        plugin.activate(host: host)
        plugin.setModelLoadTimeoutForTesting(.milliseconds(20))

        plugin.startModelLoadTimeoutForTesting(modelName: "Gemma 4 E4B")
        try await waitUntil("Gemma 4 timeout error") {
            if case .error = plugin.modelState {
                return true
            }
            return false
        }

        guard case .error(let message) = plugin.modelState else {
            return XCTFail("Expected Gemma 4 load timeout to set an error state")
        }
        XCTAssertTrue(message.contains("Gemma 4 E4B"))
        XCTAssertEqual(plugin.currentDownloadProgress, 0)
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertGreaterThanOrEqual(host.capabilitiesChangedCount, 1)
    }

    func testGemma4LateProgressFromInvalidatedLoadIsIgnored() throws {
        let plugin = Gemma4Plugin()
        let generation = plugin.startModelLoadTimeoutForTesting(modelName: "Gemma 4 E4B")

        plugin.invalidateModelLoadForTesting()
        plugin.recordModelLoadProgressForTesting(fraction: 1.0, generation: generation)

        XCTAssertEqual(plugin.currentDownloadProgress, 0)
        XCTAssertEqual(plugin.modelState, .downloading)
    }

    func testGemma4CancelInvalidatesPendingTimeout() async throws {
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))

        plugin.setModelLoadTimeoutForTesting(.milliseconds(20))
        let generation = plugin.startModelLoadTimeoutForTesting(modelName: model.displayName)
        plugin.cancelModelLoad()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(plugin.isCurrentModelLoadForTesting(generation))
        XCTAssertEqual(plugin.modelState, .notLoaded)
        XCTAssertEqual(plugin.currentDownloadProgress, 0)
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

    func testGemma4MissingWeightErrorsUseCacheRecoveryMessage() throws {
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let error = NSError(
            domain: "Test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Key embed_vision.embedding_projection.weight not found in Gemma4MultiModalEmbedder.Linear"
            ]
        )

        let message = Gemma4Plugin.userFacingLoadErrorMessage(for: error, modelDef: model)

        XCTAssertEqual(
            message,
            "The downloaded Gemma model cache appears incomplete or incompatible. Delete the cached model and download it again."
        )
    }

    func testGemma4CheckpointShapeErrorsUseCacheRecoveryMessage() throws {
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e4b-it-4bit"))
        let error = NSError(
            domain: "Test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Checkpoint tensor shape mismatch for language_model.layers.0.self_attn.q_proj.weight"
            ]
        )

        let message = Gemma4Plugin.userFacingLoadErrorMessage(for: error, modelDef: model)

        XCTAssertEqual(
            message,
            "The downloaded Gemma model cache appears incomplete or incompatible. Delete the cached model and download it again."
        )
    }

    func testGemma4ResetCachedModelDeletesCacheAndClearsLoadedState() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let modelDirectory = appSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repoId, isDirectory: true)
        let hubCacheDirectory = gemmaHubCacheDirectory(appSupportDirectory: appSupportDirectory, model: model)
        let hubLockDirectory = gemmaHubLockDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writeUsableGemmaCache(at: modelDirectory)
        try writeHubGemmaCache(at: hubCacheDirectory)
        try FileManager.default.createDirectory(at: hubLockDirectory, withIntermediateDirectories: true)

        plugin.activate(host: host)
        host.setUserDefault(model.id, forKey: "loadedModel")
        plugin.beginModelLoad(for: model, isAlreadyDownloaded: true)

        plugin.resetCachedModel(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubCacheDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubLockDirectory.path))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(plugin.modelState, .notLoaded)
        XCTAssertEqual(plugin.currentDownloadProgress, 0)
        XCTAssertGreaterThanOrEqual(host.capabilitiesChangedCount, 2)
    }

    func testGemma4UnloadModelPreservesDownloadedCache() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let host = MockHostServices(pluginDataDirectory: appSupportDirectory)
        let plugin = Gemma4Plugin()
        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let modelDirectory = gemmaModelDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writeUsableGemmaCache(at: modelDirectory)

        plugin.activate(host: host)
        try await Task.sleep(nanoseconds: 10_000_000)
        host.setUserDefault(model.id, forKey: "loadedModel")
        plugin.beginModelLoad(for: model, isAlreadyDownloaded: true)

        plugin.unloadModel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertTrue(plugin.isModelDownloaded(model))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(plugin.modelState, .notLoaded)
        XCTAssertEqual(plugin.currentDownloadProgress, 0)
    }

    func testGemma4DeleteDownloadedModelClearsSelectionAndCache() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: ["selectedLLMModel": model.id]
        )
        let plugin = Gemma4Plugin()
        let modelDirectory = gemmaModelDirectory(appSupportDirectory: appSupportDirectory, model: model)
        let hubCacheDirectory = gemmaHubCacheDirectory(appSupportDirectory: appSupportDirectory, model: model)
        let hubLockDirectory = gemmaHubLockDirectory(appSupportDirectory: appSupportDirectory, model: model)
        try writeUsableGemmaCache(at: modelDirectory)
        try writeHubGemmaCache(at: hubCacheDirectory)
        try FileManager.default.createDirectory(at: hubLockDirectory, withIntermediateDirectories: true)

        plugin.activate(host: host)
        try await Task.sleep(nanoseconds: 10_000_000)
        host.setUserDefault(model.id, forKey: "loadedModel")

        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])

        try await plugin.deleteDownloadedModel(model.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubCacheDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubLockDirectory.path))
        XCTAssertNil(plugin.selectedLLMModelId)
        XCTAssertNil(host.userDefault(forKey: "selectedLLMModel"))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertGreaterThanOrEqual(host.capabilitiesChangedCount, 1)
    }

    private struct WaitUntilTimeout: Error {}

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                throw WaitUntilTimeout()
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func gemmaModelDirectory(appSupportDirectory: URL, model: Gemma4ModelDef) -> URL {
        appSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(model.repoId, isDirectory: true)
    }

    private func gemmaHubCacheDirectory(appSupportDirectory: URL, model: Gemma4ModelDef) -> URL {
        appSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("models--" + model.repoId.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private func gemmaHubLockDirectory(appSupportDirectory: URL, model: Gemma4ModelDef) -> URL {
        appSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent("models--" + model.repoId.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private func writePartialGemmaCache(at modelDirectory: URL) throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: modelDirectory.appendingPathComponent("model.safetensors"))
    }

    private func writeUsableGemmaCache(at modelDirectory: URL) throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("tokenizer.json"))
        try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent("model.safetensors"))
    }

    private func writeHubGemmaCache(at cacheDirectory: URL) throws {
        let snapshotDirectory = cacheDirectory
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("revision", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        try Data("hub weights".utf8).write(to: snapshotDirectory.appendingPathComponent("model.safetensors"))
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

    func testWhisperKitActivationKeepsPersistedLoadedModelForAutoRestore() throws {
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
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
    }

}

final class PluginDictionaryGuardTests: XCTestCase {
    func testWhisperKitConditioningPromptClampsPlainTermListsTo500Characters() {
        let prompt = PluginDictionaryTerms.prompt(from: makeLongTerms(count: 80, length: 18), maxLength: 10_000)
        let conditioned = WhisperKitPlugin.conditioningPrompt(from: prompt)

        XCTAssertNotNil(conditioned)
        XCTAssertTrue(conditioned?.hasPrefix("The audio may contain these names or technical terms: ") == true)
        XCTAssertLessThanOrEqual(conditioned?.count ?? .max, 500)
    }

    func testWhisperKitSanitizedStreamingTextRemovesConditioningPromptPrefix() {
        let prompt = "AssemblyAI, Deepgram, Gemini, Nova 2, Nova 3, OpenAI, Speechmatics, Whisper"
        let conditioned = WhisperKitPlugin.conditioningPrompt(from: prompt)

        XCTAssertEqual(
            WhisperKitPlugin.sanitizedStreamingText(
                "\(conditioned ?? "") hello world",
                conditioningPrompt: conditioned
            ),
            "hello world"
        )
    }

    func testDeepgramSupportedLanguagesIncludeMultilingualCodeSwitchingMode() {
        XCTAssertTrue(DeepgramPlugin().supportedLanguages.contains("multi"))
    }

    func testDeepgramDictionaryQueryItemsLimitDictionaryTermsTo100AndPreserveOrder() {
        let prompt = PluginDictionaryTerms.prompt(from: makeLongTerms(count: 150, length: 10), maxLength: 10_000)
        let queryItems = DeepgramPlugin.dictionaryQueryItems(prompt: prompt, modelId: "nova-2")

        XCTAssertEqual(queryItems.count, 100)
        XCTAssertTrue(queryItems.allSatisfy { $0.name == "keywords" })
        XCTAssertEqual(queryItems.first?.value, "Term1-xxxx")
        XCTAssertEqual(queryItems.last?.value, "Term100-xx")
    }

    @available(macOS 26, *)
    func testSpeechAnalyzerAnalysisContextLimitsDictionaryTermsTo100() {
        let prompt = PluginDictionaryTerms.prompt(from: makeLongTerms(count: 150, length: 10), maxLength: 10_000)
        let context = SpeechAnalyzerPlugin.analysisContext(from: prompt)
        let terms = context.contextualStrings[.general] ?? []

        XCTAssertEqual(terms.count, 100)
        XCTAssertEqual(terms.first, "Term1-xxxx")
        XCTAssertEqual(terms.last, "Term100-xx")
    }

    private func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }
}

final class ModelManagerActiveModelNameTests: XCTestCase {
    @MainActor
    func testActiveModelNameUsesCatalogDisplayNameForPersistedSelection() {
        let plugin = CatalogBackedTranscriptionPlugin(
            providerDisplayName: "Apple Speech",
            isConfigured: false,
            transcriptionModels: [],
            availableModels: [
                PluginModelInfo(id: "speechanalyzer-de_DE", displayName: "German (Germany)")
            ],
            selectedModelId: "speechanalyzer-de_DE"
        )

        XCTAssertEqual(ModelManagerService.activeModelName(for: plugin), "German (Germany)")
    }

    @MainActor
    func testActiveModelNameFallsBackToProviderNameForConfiguredModelessEngine() {
        let plugin = CatalogBackedTranscriptionPlugin(
            providerDisplayName: "Modeless Engine",
            isConfigured: true,
            transcriptionModels: [],
            availableModels: [],
            selectedModelId: nil
        )

        XCTAssertEqual(ModelManagerService.activeModelName(for: plugin), "Modeless Engine")
    }

    @MainActor
    func testActiveModelNameFallsBackToProviderNameForSelectedModelWithoutCatalog() {
        let plugin = CatalogBackedTranscriptionPlugin(
            providerDisplayName: "Apple Speech",
            isConfigured: false,
            transcriptionModels: [],
            availableModels: [],
            selectedModelId: "speechanalyzer-de_DE"
        )

        XCTAssertEqual(ModelManagerService.activeModelName(for: plugin), "Apple Speech")
    }

    @MainActor
    func testActiveModelNameIsNilForUnconfiguredEngineWithoutSelection() {
        let plugin = CatalogBackedTranscriptionPlugin(
            providerDisplayName: "Unconfigured Engine",
            isConfigured: false,
            transcriptionModels: [],
            availableModels: [],
            selectedModelId: nil
        )

        XCTAssertNil(ModelManagerService.activeModelName(for: plugin))
    }
}

@available(macOS 26, *)
final class SpeechAnalyzerSelectionPersistenceTests: XCTestCase {
    func testSelectedModelIdUsesPersistedLoadedModelWhenRuntimeModelIsUnloaded() {
        let host = TestHostServices(userDefaults: ["loadedModel": "speechanalyzer-de_DE"])

        XCTAssertEqual(
            SpeechAnalyzerPlugin.selectedModelId(loadedModelId: nil, host: host),
            "speechanalyzer-de_DE"
        )
    }

    func testSelectedModelIdPrefersRuntimeModelOverPersistedLoadedModel() {
        let host = TestHostServices(userDefaults: ["loadedModel": "speechanalyzer-de_DE"])

        XCTAssertEqual(
            SpeechAnalyzerPlugin.selectedModelId(loadedModelId: "speechanalyzer-en_US", host: host),
            "speechanalyzer-en_US"
        )
    }
}

private final class CatalogBackedTranscriptionPlugin: NSObject, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "test.catalog-backed-transcription-plugin"
    static let pluginName = "Catalog Backed Transcription Plugin"

    let providerId: String
    let providerDisplayName: String
    let isConfigured: Bool
    let transcriptionModels: [PluginModelInfo]
    let availableModels: [PluginModelInfo]
    let selectedModelId: String?
    let supportsTranslation = false
    let supportsStreaming = false
    let supportedLanguages: [String] = []

    required override init() {
        self.providerId = Self.pluginId
        self.providerDisplayName = Self.pluginName
        self.isConfigured = false
        self.transcriptionModels = []
        self.availableModels = []
        self.selectedModelId = nil
        super.init()
    }

    init(
        providerId: String = "catalogBacked",
        providerDisplayName: String,
        isConfigured: Bool,
        transcriptionModels: [PluginModelInfo],
        availableModels: [PluginModelInfo],
        selectedModelId: String?
    ) {
        self.providerId = providerId
        self.providerDisplayName = providerDisplayName
        self.isConfigured = isConfigured
        self.transcriptionModels = transcriptionModels
        self.availableModels = availableModels
        self.selectedModelId = selectedModelId
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        throw PluginTranscriptionError.notConfigured
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        throw PluginTranscriptionError.notConfigured
    }
}

private final class TestHostServices: HostServices, @unchecked Sendable {
    private var userDefaults: [String: Any]

    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol = TestEventBus()
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let availableRuleNames: [String] = []
    let availableWorkflows: [PluginWorkflowInfo] = []

    init(userDefaults: [String: Any] = [:]) {
        self.userDefaults = userDefaults
        self.pluginDataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisperTests-\(UUID().uuidString)", isDirectory: true)
    }

    func storeSecret(key: String, value: String) throws {}
    func loadSecret(key: String) -> String? { nil }
    func userDefault(forKey key: String) -> Any? { userDefaults[key] }

    func setUserDefault(_ value: Any?, forKey key: String) {
        userDefaults[key] = value
    }

    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

private final class TestEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        UUID()
    }

    func unsubscribe(id: UUID) {}
}

final class WhisperKitSettingsStateTests: XCTestCase {
    func testApplyingNotLoadedStateClearsStaleLoadingAndStopsPolling() {
        let initial = WhisperKitSettingsPollState(
            modelState: .loading(phase: "loading"),
            downloadProgress: 0.9,
            activeModelId: "openai_whisper-large-v3_turbo",
            isPolling: true
        )

        let updated = initial.applyingPolledPluginState(
            .notLoaded,
            downloadProgress: 0,
            selectedModelId: "openai_whisper-large-v3_turbo"
        )

        XCTAssertEqual(updated.modelState, .notLoaded)
        XCTAssertEqual(updated.downloadProgress, 0)
        XCTAssertEqual(updated.activeModelId, "openai_whisper-large-v3_turbo")
        XCTAssertFalse(updated.isPolling)
    }

    func testBusyStateTreatsPrewarmingAsLoading() {
        let state = WhisperKitSettingsPollState(
            modelState: .loading(phase: "prewarming"),
            downloadProgress: 0.9,
            activeModelId: "openai_whisper-large-v3_turbo",
            isPolling: true
        )

        XCTAssertTrue(state.isBusy)
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
    func testQwen3ContextFormatterIncludesBaseInstructionWithoutPrompt() throws {
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: nil),
            Qwen3ContextBiasFormatter.baseInstruction
        )
    }

    func testQwen3ContextFormatterWrapsSingleTerm() throws {
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: "Qwen3"),
            "\(Qwen3ContextBiasFormatter.baseInstruction)\nTechnical terms: Qwen3."
        )
    }

    func testQwen3ContextFormatterWrapsMultipleTermsAsCommaSeparatedSentence() throws {
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: "Qwen3, MLX, LoRA"),
            "\(Qwen3ContextBiasFormatter.baseInstruction)\nTechnical terms: Qwen3, MLX, LoRA."
        )
    }

    func testQwen3ContextFormatterPreservesNormalizedAndDeduplicatedTerms() throws {
        let prompt = PluginDictionaryTerms.prompt(from: [" Kubernetes ", "MLX", "mlx", "TypeWhisper"])
        XCTAssertEqual(
            Qwen3ContextBiasFormatter.format(prompt: prompt),
            "\(Qwen3ContextBiasFormatter.baseInstruction)\nTechnical terms: Kubernetes, MLX, TypeWhisper."
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

    private final class MockRoleGatedTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, PluginAuthRoleStatusProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.role-gated" }
        static var pluginName: String { "Mock Role Gated" }

        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "mock-role-gated" }
        var providerDisplayName: String { "Mock Role Gated" }
        var isConfigured: Bool { true }
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["en"] }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        func selectModel(_ modelId: String) {}

        func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
            role == .transcription
                ? PluginAuthRoleStatus(
                    isAvailable: false,
                    unavailableReason: "Transcription needs a separate credential.",
                    requiredCredentialLabel: "API key"
                )
                : .available
        }

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
                source: .official,
                name: "Marketplace Replacement",
                version: "1.3.1",
                minHostVersion: "1.3.0",
                sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                minOSVersion: nil,
                supportedArchitectures: nil,
                author: "TypeWhisper",
                description: "Replacement",
                category: "utility",
                categories: ["utility"],
                size: 1,
                downloadURL: "https://example.com/replacement.zip",
                iconSystemName: nil,
                requiresAPIKey: nil,
                hosting: nil,
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
            source: .official,
            name: "ARM64 Only",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            minOSVersion: "14.0",
            supportedArchitectures: ["arm64"],
            author: "TypeWhisper",
            description: "Test plugin",
            category: "transcription",
            categories: ["transcription"],
            size: 1,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            hosting: nil,
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

    func testModelManagerFallsBackWhenStoredProviderCannotUseTranscriptionRole() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.set("mock-role-gated", forKey: selectedEngineKey)
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
                    id: "com.typewhisper.mock.role-gated",
                    name: "Mock Role Gated",
                    version: "1.0.0",
                    principalClass: "MockRoleGatedTranscriptionPlugin"
                ),
                instance: MockRoleGatedTranscriptionPlugin(),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
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

    func testRepairEligibilityRequiresActionableExternalBundleNotice() {
        let registryPlugin = makeRegistryPlugin(id: "com.typewhisper.qwen3")
        let boundaryNotice = ExternalBundleNotice.boundaryUpgradeRequired(
            installedVersion: "1.1.0",
            availableVersion: "1.1.1"
        )

        XCTAssertTrue(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: registryPlugin,
                installInfo: .installed(version: "1.1.1"),
                installState: nil,
                externalNotice: boundaryNotice
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: registryPlugin,
                installInfo: .installed(version: "1.1.1"),
                installState: nil,
                externalNotice: nil
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: registryPlugin,
                installInfo: .installed(version: "1.1.1"),
                installState: nil,
                externalNotice: .legacyBundlePresent(version: "1.1.0")
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: true,
                registryPlugin: registryPlugin,
                installInfo: .installed(version: "1.1.1"),
                installState: nil,
                externalNotice: boundaryNotice
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: nil,
                installInfo: .installed(version: "1.1.1"),
                installState: nil,
                externalNotice: boundaryNotice
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: registryPlugin,
                installInfo: .updateAvailable(installed: "1.1.0", available: "1.1.1"),
                installState: nil,
                externalNotice: boundaryNotice
            )
        )
        XCTAssertFalse(
            PluginRegistryService.canRepairInstalledPlugin(
                isBundled: false,
                registryPlugin: registryPlugin,
                installInfo: .installed(version: "1.1.1"),
                installState: .extracting,
                externalNotice: boundaryNotice
            )
        )
    }

    func testRepairInstallKeepsManagedBundlePathAndPluginDataDirectory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "PluginRepairDestination")
        defer { TestSupport.remove(appSupportDirectory) }

        let pluginsDirectory = appSupportDirectory.appendingPathComponent("Plugins", isDirectory: true)
        let pluginDataDirectory = appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent("com.typewhisper.qwen3", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginDataDirectory, withIntermediateDirectories: true)
        let sentinelURL = pluginDataDirectory.appendingPathComponent("model-cache-sentinel")
        try Data("keep model cache".utf8).write(to: sentinelURL)

        let existingURL = pluginsDirectory.appendingPathComponent("Qwen3Plugin.bundle", isDirectory: true)
        let destination = PluginRegistryService.resolveInstallDestinationURL(
            currentURL: existingURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            incomingBundleName: "Qwen3Plugin.bundle"
        )

        XCTAssertEqual(destination, existingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
    }

    private func makeRegistryPlugin(id: String) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            source: .official,
            name: "Qwen3 ASR",
            version: "1.1.1",
            minHostVersion: "1.4.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            minOSVersion: "14.0",
            supportedArchitectures: ["arm64"],
            author: "TypeWhisper",
            description: "Local model plugin",
            category: "transcription",
            categories: ["transcription"],
            size: 1,
            downloadURL: "https://example.com/Qwen3Plugin.zip",
            iconSystemName: "cpu",
            requiresAPIKey: false,
            hosting: .local,
            descriptions: nil,
            downloadCount: nil
        )
    }
}

final class PluginDiagnosticsSupportTests: XCTestCase {
    func testPluginSourceClassifiesBundledManagedAndExternalPaths() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "PluginDiagnostics")
        defer { TestSupport.remove(root) }

        let builtInPluginsURL = root.appendingPathComponent("TypeWhisper.app/Contents/PlugIns", isDirectory: true)
        let pluginsDirectory = root.appendingPathComponent("Application Support/TypeWhisper/Plugins", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External", isDirectory: true)

        let bundledURL = try makeMockBundle(in: builtInPluginsURL, name: "BundledPlugin")
        let managedURL = try makeMockBundle(in: pluginsDirectory, name: "ManagedPlugin")
        let externalURL = try makeMockBundle(in: externalDirectory, name: "ExternalPlugin")

        let bundled = await PluginDiagnosticsSupport.sourceInfo(
            bundle: try XCTUnwrap(Bundle(url: bundledURL)),
            sourceURL: bundledURL,
            builtInPluginsURL: builtInPluginsURL,
            pluginsDirectory: pluginsDirectory,
            homeDirectory: root
        )
        let managed = await PluginDiagnosticsSupport.sourceInfo(
            bundle: try XCTUnwrap(Bundle(url: managedURL)),
            sourceURL: managedURL,
            builtInPluginsURL: builtInPluginsURL,
            pluginsDirectory: pluginsDirectory,
            homeDirectory: root
        )
        let external = await PluginDiagnosticsSupport.sourceInfo(
            bundle: try XCTUnwrap(Bundle(url: externalURL)),
            sourceURL: externalURL,
            builtInPluginsURL: builtInPluginsURL,
            pluginsDirectory: pluginsDirectory,
            homeDirectory: root
        )

        XCTAssertEqual(bundled.sourceKind, .bundled)
        XCTAssertEqual(managed.sourceKind, .managedExternal)
        XCTAssertEqual(external.sourceKind, .externalOther)
        XCTAssertTrue(managed.pathHint.hasPrefix("~/"))
        XCTAssertFalse(managed.pathHint.contains(root.path))
    }

    func testPluginSourcePathHintCanonicalizesSymlinkedBundles() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "PluginDiagnosticsSymlink")
        defer { TestSupport.remove(root) }

        let realHome = root.appendingPathComponent("real-home", isDirectory: true)
        let symlinkHome = root.appendingPathComponent("symlink-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkHome, withDestinationURL: realHome)

        let pluginsDirectory = realHome.appendingPathComponent("Application Support/TypeWhisper/Plugins", isDirectory: true)
        let bundleURL = try makeMockBundle(in: pluginsDirectory, name: "SymlinkPlugin")
        let symlinkedBundleURL = symlinkHome
            .appendingPathComponent("Application Support/TypeWhisper/Plugins", isDirectory: true)
            .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)

        let source = await PluginDiagnosticsSupport.sourceInfo(
            bundle: try XCTUnwrap(Bundle(url: symlinkedBundleURL)),
            sourceURL: symlinkedBundleURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            homeDirectory: realHome
        )

        XCTAssertEqual(source.sourceKind, .managedExternal)
        XCTAssertTrue(source.pathHint.hasPrefix("~/"))
        XCTAssertFalse(source.pathHint.contains(symlinkHome.path))
    }

    func testPluginSourceReportsExecutableSizeAndHash() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "PluginDiagnosticsHash")
        defer { TestSupport.remove(root) }

        let pluginsDirectory = root.appendingPathComponent("Plugins", isDirectory: true)
        let bundleURL = try makeMockBundle(
            in: pluginsDirectory,
            name: "HashPlugin",
            executableData: Data("hash me".utf8)
        )

        let source = await PluginDiagnosticsSupport.sourceInfo(
            bundle: try XCTUnwrap(Bundle(url: bundleURL)),
            sourceURL: bundleURL,
            builtInPluginsURL: nil,
            pluginsDirectory: pluginsDirectory,
            homeDirectory: root
        )

        XCTAssertEqual(source.executableSizeBytes, 7)
        XCTAssertEqual(source.executableSHA256?.count, 64)
        XCTAssertEqual(source.bundleIdentifier, "com.typewhisper.tests.HashPlugin")
        XCTAssertEqual(source.bundleShortVersion, "1.0.0")
        XCTAssertEqual(source.bundleVersion, "1")
    }

    private func makeMockBundle(
        in parentDirectory: URL,
        name: String,
        executableData: Data = Data("mock executable".utf8)
    ) throws -> URL {
        let bundleURL = parentDirectory.appendingPathComponent("\(name).bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>\(name)</string>
            <key>CFBundleIdentifier</key>
            <string>com.typewhisper.tests.\(name)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundlePackageType</key>
            <string>BNDL</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>
        """
        try Data(infoPlist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))
        try executableData.write(to: macOSURL.appendingPathComponent(name))
        return bundleURL
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
