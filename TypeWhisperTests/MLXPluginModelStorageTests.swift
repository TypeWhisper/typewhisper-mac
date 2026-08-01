import Foundation
import XCTest
@testable import TypeWhisper
import TypeWhisperPluginSDK

final class MLXPluginModelStorageTests: XCTestCase {
    private let commit = String(repeating: "b", count: 40)

    func testModelCatalogsRecognizeLegacyAndCanonicalLayouts() throws {
        try assertCatalogRecognizesBothLayouts(
            plugin: Qwen3Plugin(),
            modelID: Qwen3Plugin.availableModels[0].id,
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"]
        )
        try assertCatalogRecognizesBothLayouts(
            plugin: GranitePlugin(),
            modelID: GranitePlugin.availableModels[0].id,
            repositoryID: GranitePlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tokenizer.json"]
        )
        try assertCatalogRecognizesBothLayouts(
            plugin: VoxtralPlugin(),
            modelID: VoxtralPlugin.availableModels[0].id,
            repositoryID: VoxtralPlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tekken.json"]
        )

        let gemmaModel = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let gemmaFixture = try Fixture()
        defer { gemmaFixture.remove() }
        let gemmaHost = MockHostServices(pluginDataDirectory: gemmaFixture.root)
        let gemma = Gemma4Plugin()
        gemma.activate(host: gemmaHost)
        let gemmaLegacy = gemmaFixture.legacyDirectory(repositoryID: gemmaModel.repoId, usesMLXAudio: false)
        try gemmaFixture.writeModel(at: gemmaLegacy, requiredFiles: ["config.json", "tokenizer.json"])
        XCTAssertEqual(gemma.downloadedModels.map(\.id), [gemmaModel.id])
        try FileManager.default.removeItem(at: gemmaLegacy)
        _ = try gemmaFixture.writeSnapshot(
            repositoryID: gemmaModel.repoId,
            commit: commit,
            requiredFiles: ["config.json", "tokenizer.json"]
        )
        XCTAssertEqual(gemma.downloadedModels.map(\.id), [gemmaModel.id])
    }

    func testActivationRemovesVerifiedDuplicateCopiesForAllPlugins() throws {
        try assertActivationRemovesDuplicate(
            plugin: Qwen3Plugin(),
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"],
            usesMLXAudio: true
        )
        try assertActivationRemovesDuplicate(
            plugin: GranitePlugin(),
            repositoryID: GranitePlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tokenizer.json"],
            usesMLXAudio: true
        )
        try assertActivationRemovesDuplicate(
            plugin: VoxtralPlugin(),
            repositoryID: VoxtralPlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tekken.json"],
            usesMLXAudio: true
        )

        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        try assertActivationRemovesDuplicate(
            plugin: Gemma4Plugin(),
            repositoryID: model.repoId,
            requiredFiles: ["config.json", "tokenizer.json"],
            usesMLXAudio: false
        )
    }

    func testUIDeletionRemovesLegacyAndCanonicalArtifactsForAllPlugins() async throws {
        try await assertDeletionRemovesAllArtifacts(
            plugin: Qwen3Plugin(),
            modelID: Qwen3Plugin.availableModels[0].id,
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"],
            usesMLXAudio: true
        )
        try await assertDeletionRemovesAllArtifacts(
            plugin: GranitePlugin(),
            modelID: GranitePlugin.availableModels[0].id,
            repositoryID: GranitePlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tokenizer.json"],
            usesMLXAudio: true
        )
        try await assertDeletionRemovesAllArtifacts(
            plugin: VoxtralPlugin(),
            modelID: VoxtralPlugin.availableModels[0].id,
            repositoryID: VoxtralPlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tekken.json"],
            usesMLXAudio: true
        )

        let model = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        try await assertDeletionRemovesAllArtifacts(
            plugin: Gemma4Plugin(),
            modelID: model.id,
            repositoryID: model.repoId,
            requiredFiles: ["config.json", "tokenizer.json"],
            usesMLXAudio: false
        )
    }

    func testVoxtralUsesActualCacheRootAndDeletesHistoricalWrongRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = VoxtralPlugin.availableModels[0]
        let plugin = VoxtralPlugin()
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        let actualSnapshot = try fixture.writeSnapshot(
            repositoryID: model.repoId,
            commit: commit,
            requiredFiles: ["config.json", "tekken.json"]
        )
        let historicalRoot = fixture.modelsDirectory.appendingPathComponent("huggingface/hub", isDirectory: true)
        let historicalSnapshot = try fixture.writeSnapshot(
            repositoryID: model.repoId,
            commit: commit,
            requiredFiles: ["config.json", "tekken.json"],
            cacheRoot: historicalRoot
        )

        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])
        try FileManager.default.removeItem(at: fixture.repositoryDirectory(repositoryID: model.repoId))
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])
        try await plugin.deleteDownloadedModel(model.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: actualSnapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: historicalSnapshot.path))
    }

    func testPassiveOfflineRestoreDoesNotCreateDownloadArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let qwen = Qwen3Plugin.availableModels[0]
        let granite = GranitePlugin.availableModels[0]
        let voxtral = VoxtralPlugin.availableModels[0]
        let gemma = try XCTUnwrap(Gemma4Plugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let plugins: [(TypeWhisperPlugin, MockHostServices)] = [
            (Qwen3Plugin(), MockHostServices(
                pluginDataDirectory: fixture.root.appendingPathComponent("qwen"),
                defaults: ["loadedModel": qwen.id],
                shouldRestoreLoadedModelsPassively: true
            )),
            (GranitePlugin(), MockHostServices(
                pluginDataDirectory: fixture.root.appendingPathComponent("granite"),
                defaults: ["loadedModel": granite.id],
                shouldRestoreLoadedModelsPassively: true
            )),
            (VoxtralPlugin(), MockHostServices(
                pluginDataDirectory: fixture.root.appendingPathComponent("voxtral"),
                defaults: ["loadedModel": voxtral.id],
                shouldRestoreLoadedModelsPassively: true
            )),
            (Gemma4Plugin(), MockHostServices(
                pluginDataDirectory: fixture.root.appendingPathComponent("gemma"),
                defaults: ["loadedModel": gemma.id],
                shouldRestoreLoadedModelsPassively: true
            )),
        ]
        for (plugin, host) in plugins {
            plugin.activate(host: host)
        }

        try await Task.sleep(for: .milliseconds(100))

        for pluginRoot in ["qwen", "granite", "voxtral", "gemma"] {
            let models = fixture.root.appendingPathComponent(pluginRoot).appendingPathComponent("models")
            XCTAssertFalse(FileManager.default.fileExists(atPath: models.path), "Unexpected cache for \(pluginRoot)")
        }
        withExtendedLifetime(plugins) {}
    }

    private func assertCatalogRecognizesBothLayouts<P: TypeWhisperPlugin & PluginDownloadedModelManaging & TranscriptionModelCatalogProviding>(
        plugin: P,
        modelID: String,
        repositoryID: String,
        requiredFiles: [String]
    ) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        plugin.activate(host: host)
        let legacy = fixture.legacyDirectory(repositoryID: repositoryID, usesMLXAudio: true)
        try fixture.writeModel(at: legacy, requiredFiles: requiredFiles)
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [modelID])
        try FileManager.default.removeItem(at: legacy)
        _ = try fixture.writeSnapshot(
            repositoryID: repositoryID,
            commit: commit,
            requiredFiles: requiredFiles
        )
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [modelID])
    }

    private func assertActivationRemovesDuplicate<P: TypeWhisperPlugin>(
        plugin: P,
        repositoryID: String,
        requiredFiles: [String],
        usesMLXAudio: Bool
    ) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.legacyDirectory(repositoryID: repositoryID, usesMLXAudio: usesMLXAudio)
        try fixture.writeModel(at: legacy, requiredFiles: requiredFiles)
        _ = try fixture.writeSnapshot(
            repositoryID: repositoryID,
            commit: commit,
            requiredFiles: requiredFiles
        )

        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    private func assertDeletionRemovesAllArtifacts<P: TypeWhisperPlugin & PluginDownloadedModelManaging>(
        plugin: P,
        modelID: String,
        repositoryID: String,
        requiredFiles: [String],
        usesMLXAudio: Bool
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        let legacy = fixture.legacyDirectory(repositoryID: repositoryID, usesMLXAudio: usesMLXAudio)
        try fixture.writeModel(at: legacy, requiredFiles: requiredFiles)
        let snapshot = try fixture.writeSnapshot(
            repositoryID: repositoryID,
            commit: commit,
            requiredFiles: requiredFiles
        )
        let repository = fixture.repositoryDirectory(repositoryID: repositoryID)
        let metadata = fixture.metadataDirectory(repositoryID: repositoryID)
        let locks = fixture.lockDirectory(repositoryID: repositoryID)
        try fixture.write("metadata", to: metadata.appendingPathComponent("entry"))
        try fixture.write("lock", to: locks.appendingPathComponent("entry.lock"))

        try await plugin.deleteDownloadedModel(modelID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locks.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.modelsDirectory.path))
    }
}

private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
}

private final class MockHostServices: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    private var defaults: [String: Any]

    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol = MockEventBus()
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let availableRuleNames: [String] = []
    let shouldRestoreLoadedModelsPassively: Bool

    init(
        pluginDataDirectory: URL,
        defaults: [String: Any] = [:],
        shouldRestoreLoadedModelsPassively: Bool = false
    ) {
        self.pluginDataDirectory = pluginDataDirectory
        self.defaults = defaults
        self.shouldRestoreLoadedModelsPassively = shouldRestoreLoadedModelsPassively
    }

    func storeSecret(key: String, value: String) throws {}
    func loadSecret(key: String) -> String? { nil }
    func userDefault(forKey key: String) -> Any? { defaults[key] }
    func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

private final class Fixture {
    let root: URL
    let modelsDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func repositoryDirectory(repositoryID: String, cacheRoot: URL? = nil) -> URL {
        (cacheRoot ?? modelsDirectory).appendingPathComponent(
            "models--" + repositoryID.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
    }

    func metadataDirectory(repositoryID: String) -> URL {
        modelsDirectory
            .appendingPathComponent(".metadata", isDirectory: true)
            .appendingPathComponent("models--" + repositoryID.replacingOccurrences(of: "/", with: "--"))
    }

    func lockDirectory(repositoryID: String) -> URL {
        modelsDirectory
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent("models--" + repositoryID.replacingOccurrences(of: "/", with: "--"))
    }

    func legacyDirectory(repositoryID: String, usesMLXAudio: Bool) -> URL {
        if usesMLXAudio {
            return modelsDirectory
                .appendingPathComponent("mlx-audio", isDirectory: true)
                .appendingPathComponent(repositoryID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        }
        return modelsDirectory.appendingPathComponent(repositoryID, isDirectory: true)
    }

    func writeSnapshot(
        repositoryID: String,
        commit: String,
        requiredFiles: [String],
        cacheRoot: URL? = nil
    ) throws -> URL {
        let repository = repositoryDirectory(repositoryID: repositoryID, cacheRoot: cacheRoot)
        let snapshot = repository.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        try writeModel(at: snapshot, requiredFiles: requiredFiles)
        try write(commit + "\n", to: repository.appendingPathComponent("refs/main"))
        return snapshot
    }

    func writeModel(at directory: URL, requiredFiles: [String]) throws {
        for file in requiredFiles {
            try write(file == "merges.txt" ? "#version: 0.2\na b" : "{}", to: directory.appendingPathComponent(file))
        }
        try write("weights", to: directory.appendingPathComponent("model.safetensors"))
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
