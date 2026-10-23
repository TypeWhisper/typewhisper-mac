import Combine
import Foundation
import os
import SwiftUI
import XCTest
@testable import TypeWhisper
@_spi(Testing) import TypeWhisperPluginSDK

final class MLXPluginModelStorageTests: XCTestCase {
    private let commit = String(repeating: "b", count: 40)

    @MainActor
    func testExplicitLoadHandlerAcceptsImportedModelIDs() async throws {
        let qwen = Qwen3Plugin()
        try await assertExplicitLoadRequest(qwen, gate: qwen.modelLoadGate)
    }

    @MainActor
    func testSetupWizardActivationDownloadsMissingQwen3Model() async throws {
        let session = SuspendedDownloadSession()
        PluginHTTPClient.configureForTesting { _ in session }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        defer { PluginHTTPClient.resetTestingHooks() }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        let qwen = Qwen3Plugin()
        qwen.activate(host: host)
        defer { qwen.deactivate() }

        let activation = Task { try await SetupWizardQwen3Recommendation.activate(qwen) { _ in } }
        defer { activation.cancel() }
        for _ in 0..<500 where session.requestedRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(qwen.explicitModelLoadTask)
        XCTAssertEqual(qwen.currentSettingsActivity?.isError, false)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "qwen3-asr-1.7b-6bit")
        XCTAssertFalse(qwen.isConfigured)
        XCTAssertEqual(session.requestedRequests.count, 1)
        XCTAssertEqual(session.requestedRequests.first?.url?.host, "huggingface.co")
        XCTAssertEqual(session.requestedRequests.map { $0.url?.path }, [
            "/api/models/mlx-community/Qwen3-ASR-1.7B-6bit/tree/main",
        ])
        activation.cancel()
        try await activation.value
        let download = qwen.explicitModelLoadTask
        download?.cancel()
        await download?.value
        XCTAssertEqual(session.requestedRequests.count, 1)
    }

    @MainActor
    func testSetupWizardRetryReportsTheNewAttemptsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = "custom-" + UUID().uuidString.lowercased()
        let folder = fixture.root.appendingPathComponent("custom-models/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": "Incomplete", "modelType": "qwen3_asr", "origin": "folder", "bytes": 0,
        ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        let qwen = Qwen3Plugin()
        qwen.activate(host: host)
        defer { qwen.deactivate() }
        qwen.selectModel(id)
        for _ in 0..<2 {
            var progressUpdates = 0
            do {
                try await SetupWizardQwen3Recommendation.activate(qwen) { _ in progressUpdates += 1 }
                XCTFail("Missing imported files must fail preparation")
            } catch TranscriptionEngineError.modelLoadFailed(let message) {
                XCTAssertTrue(message.contains("Imported files are missing"))
            }
            XCTAssertGreaterThan(progressUpdates, 0)
        }
    }

    @MainActor
    func testSetupWizardFollowsRunningDownloadInsteadOfRestartingIt() async throws {
        let session = SuspendedDownloadSession()
        PluginHTTPClient.configureForTesting { _ in session }
        PluginHTTPClient.configureRetryForTesting(sleeper: { _ in })
        defer { PluginHTTPClient.resetTestingHooks() }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let modelDef = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == "qwen3-asr-1.7b-6bit" })
        let partialFile = fixture.repositoryDirectory(repositoryID: modelDef.repoId)
            .appendingPathComponent("blobs/partial")
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        let qwen = Qwen3Plugin()
        qwen.activate(host: host)
        defer { qwen.deactivate() }

        let first = Task { try await SetupWizardQwen3Recommendation.activate(qwen) { _ in } }
        defer { first.cancel() }
        for _ in 0..<500 where session.requestedRequests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let runningTask = try XCTUnwrap(qwen.explicitModelLoadTask)
        XCTAssertEqual(session.requestedRequests.count, 1)
        XCTAssertEqual(session.requestedRequests.map { $0.url?.path }, [
            "/api/models/\(modelDef.repoId)/tree/main",
        ])
        try FileManager.default.createDirectory(at: partialFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partialFile)

        let second = Task { try await SetupWizardQwen3Recommendation.activate(qwen) { _ in } }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(runningTask.isCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialFile.path))
        XCTAssertEqual(try Data(contentsOf: partialFile), Data("partial".utf8))
        XCTAssertEqual(session.requestedRequests.count, 1)

        first.cancel()
        second.cancel()
        try await first.value
        try await second.value
        runningTask.cancel()
        await runningTask.value
        XCTAssertEqual(session.requestedRequests.count, 1)
    }

    @MainActor
    func testNewExplicitRequestCancelsPreviousRequestBeforeTasksStart() async throws {
        try await assertSupersededExplicitRequests(allowFirstTaskToStart: false)
    }

    @MainActor
    func testNewExplicitRequestCancelsPreviousRequestWaitingForLoadGate() async throws {
        try await assertSupersededExplicitRequests(allowFirstTaskToStart: true)
    }

    @MainActor
    func testSelectingAnotherModelInvalidatesPendingExplicitLoad() async throws {
        try await assertSupersededExplicitRequests(allowFirstTaskToStart: true, selectionOnly: true)
    }

    @MainActor
    private func assertSupersededExplicitRequests(allowFirstTaskToStart: Bool, selectionOnly: Bool = false) async throws {
        let qwen = Qwen3Plugin()
        try await assertSupersededRequests(qwen, gate: qwen.modelLoadGate,
            allowFirstTaskToStart: allowFirstTaskToStart, selectionOnly: selectionOnly, currentTask: { qwen.explicitModelLoadTask })
    }

    @MainActor
    private func assertSupersededRequests<P: NSObject & TranscriptionEnginePlugin>(
        _ plugin: P, gate: PluginLocalInferenceGate, allowFirstTaskToStart: Bool, selectionOnly: Bool,
        currentTask: @escaping @MainActor @Sendable () -> Task<Void, Never>?
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ids = (0..<2).map { _ in "custom-" + UUID().uuidString.lowercased() }
        for id in ids {
            let folder = fixture.root.appendingPathComponent("custom-models/" + id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "id": id, "displayName": id, "modelType": "fixture", "origin": "fixture", "bytes": 0,
            ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        }
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        plugin.activate(host: host)
        try await gate.withLock {
            let (first, latest): (Task<Void, Never>?, Task<Void, Never>?)
            if allowFirstTaskToStart {
                first = await MainActor.run {
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[0] as NSString)
                    return currentTask()
                }
                // The held load gate prevents native loading while A starts.
                for _ in 0..<10 { await Task.yield() }
                // Competing callers and cancelled-task cleanup must not erase
                // the handle for a newer request while native loading is blocked.
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<20 {
                        group.addTask {
                            _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[0] as NSString)
                        }
                    }
                }
                latest = await MainActor.run {
                    if selectionOnly {
                        let pending = currentTask()
                        plugin.selectModel(ids[1])
                        XCTAssertTrue(pending?.isCancelled == true)
                        return currentTask()
                    }
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[1] as NSString)
                    return currentTask()
                }
            } else {
                // No suspension between requests: both tasks start only afterward.
                (first, latest) = await MainActor.run {
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[0] as NSString)
                    let first = currentTask()
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[1] as NSString)
                    return (first, currentTask())
                }
            }
            XCTAssertNotNil(first)
            XCTAssertTrue(first?.isCancelled == true)
            // A must finish even though the load gate is still held.
            await first?.value
            await MainActor.run {
                XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, ids[1])
                XCTAssertNil(host.userDefault(forKey: "loadedModel"))
                plugin.deactivate()
                if selectionOnly { XCTAssertNil(latest) }
                else { XCTAssertTrue(latest?.isCancelled == true) }
            }
            await latest?.value
        }
    }

    @MainActor
    func testAutoUnloadInvalidatesPendingImportInEveryMLXEngine() async throws {
        let qwen = Qwen3Plugin()
        try await assertSupersededImport(qwen, gate: qwen.modelLoadGate)
    }

    @MainActor
    func testExplicitLoadInvalidatesPendingImportInEveryMLXEngine() async throws {
        let qwen = Qwen3Plugin()
        try await assertSupersededImport(qwen, gate: qwen.modelLoadGate,
            replacementID: Qwen3Plugin.availableModels[0].id, currentTask: { qwen.explicitModelLoadTask })
    }

    @MainActor
    func testIncompleteImportsRemainRemovableInEveryMLXEngine() async throws {
        try await assertIncompleteImportIsRemovable(Qwen3Plugin())
    }

    @MainActor
    private func assertIncompleteImportIsRemovable<P: NSObject & PluginCustomModelImporting & PluginDownloadedModelManaging>(
        _ plugin: P
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = "custom-" + UUID().uuidString.lowercased()
        let folder = fixture.root.appendingPathComponent("custom-models/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": "Incomplete", "modelType": "fixture", "origin": "fixture", "bytes": 0,
        ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        defer { plugin.deactivate() }
        XCTAssertTrue(plugin.downloadedModels.contains(where: { $0.id == id }))
        try await plugin.deleteDownloadedModel(id)
        XCTAssertFalse(plugin.downloadedModels.contains(where: { $0.id == id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    private func assertSupersededImport<P: NSObject & PluginCustomModelImporting>(
        _ plugin: P, gate: PluginLocalInferenceGate, replacementID: String? = nil,
        currentTask: @escaping @MainActor @Sendable () -> Task<Void, Never>? = { nil }
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let modelType = try XCTUnwrap(plugin.supportedImportModelTypes.first)
        try JSONSerialization.data(withJSONObject: ["model_type": modelType])
            .write(to: source.appendingPathComponent("config.json"))
        for name in ["tokenizer.json", "tekken.json", "tokenizer.model", "vocab.json", "merges.txt"] {
            try Data("{}".utf8).write(to: source.appendingPathComponent(name))
        }
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var size = UInt64(header.count).littleEndian
        var weights = withUnsafeBytes(of: &size) { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 4))
        try weights.write(to: source.appendingPathComponent("model.safetensors"))
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let store = fixture.root.appendingPathComponent("custom-models")
        // Hold the native loader until the pending copy exists, then fire
        // the host selector before letting native loading proceed.
        let pending = try await gate.withLock {
            let task = await MainActor.run {
                Task { try await plugin.importModel(candidate, token: nil) }
            }
            var published = false
            for _ in 0..<500 {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
                if entries.contains(where: { $0.hasPrefix("custom-") }) {
                    published = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            await MainActor.run {
                XCTAssertTrue(published, "Import must reach the held native loader")
                if published {
                    if let replacementID {
                        _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: replacementID as NSString)
                        // Prevent the replacement from needing real weights; cancelling
                        // its task does not change the activation generation.
                        XCTAssertNotNil(currentTask())
                        currentTask()?.cancel()
                    } else {
                        _ = plugin.perform(NSSelectorFromString("triggerAutoUnload"))
                    }
                } else {
                    plugin.deactivate()
                }
            }
            return task
        }
        do {
            _ = try await pending.value
            XCTFail("Superseded import must not restore a model")
        } catch is CancellationError {
            // Expected: the host action invalidated this import's activation.
        }
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.path)
        XCTAssertFalse(entries.contains(where: { $0.hasPrefix("custom-") || $0.hasPrefix(".import-") }))
    }

    @MainActor
    func testExplicitLoadCancelsAndBlocksGenericRestorationInEveryMLXEngine() async throws {
        let qwen = Qwen3Plugin()
        try await assertGenericRestoreIsSuperseded(qwen, gate: qwen.modelLoadGate,
            genericTask: { qwen.genericModelLoadTask }, explicitTask: { qwen.explicitModelLoadTask })
    }

    @MainActor
    private func assertGenericRestoreIsSuperseded<P: NSObject & TranscriptionEnginePlugin>(
        _ plugin: P, gate: PluginLocalInferenceGate,
        genericTask: @escaping @MainActor @Sendable () -> Task<Void, Never>?,
        explicitTask: @escaping @MainActor @Sendable () -> Task<Void, Never>?
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ids = (0..<2).map { _ in "custom-" + UUID().uuidString.lowercased() }
        for id in ids {
            let folder = fixture.root.appendingPathComponent("custom-models/" + id)
            try fixture.writeModel(at: folder, requiredFiles: [
                "config.json", "tokenizer.json", "tokenizer.model", "tekken.json", "vocab.json", "merges.txt",
            ])
            try JSONSerialization.data(withJSONObject: [
                "id": id, "displayName": id, "modelType": "fixture", "origin": id, "bytes": 0,
            ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        }
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        host.setUserDefault(ids[0], forKey: "loadedModel")
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        try await gate.withLock {
            let previous = await MainActor.run {
                _ = plugin.perform(NSSelectorFromString("triggerRestoreModel"))
                return genericTask()
            }
            XCTAssertNotNil(previous)
            for _ in 0..<10 { await Task.yield() }
            let latest = await MainActor.run {
                _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: ids[1] as NSString)
                XCTAssertTrue(previous?.isCancelled == true)
                XCTAssertNil(host.userDefault(forKey: "loadedModel"))
                XCTAssertNil(genericTask())
                // A generic restore arriving after the explicit request must
                // not resurrect the old persisted model either.
                _ = plugin.perform(NSSelectorFromString("triggerRestoreModel"))
                XCTAssertNil(genericTask())
                let latest = explicitTask()
                XCTAssertNotNil(latest)
                latest?.cancel()
                return latest
            }
            await previous?.value
            await latest?.value
            await MainActor.run {
                XCTAssertEqual(plugin.selectedModelId, ids[1])
                XCTAssertFalse(plugin.isConfigured)
            }
        }
    }

    @MainActor
    func testDeletingModelCancelsQueuedExplicitAndGenericLoads() async throws {
        for explicit in [true, false] {
            let qwen = Qwen3Plugin()
            try await assertDeletionCancelsQueuedLoad(qwen, gate: qwen.modelLoadGate, explicit: explicit,
                modelID: Qwen3Plugin.availableModels[0].id, repositoryID: Qwen3Plugin.availableModels[0].repoId,
                task: { explicit ? qwen.explicitModelLoadTask : qwen.genericModelLoadTask })
        }
    }

    @MainActor
    private func assertDeletionCancelsQueuedLoad<P: NSObject & TranscriptionEnginePlugin & PluginDownloadedModelManaging>(
        _ plugin: P, gate: PluginLocalInferenceGate, explicit: Bool, modelID: String, repositoryID: String,
        task: @escaping @MainActor @Sendable () -> Task<Void, Never>?
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = try fixture.writeSnapshot(repositoryID: repositoryID, commit: commit, requiredFiles: [
            "config.json", "tokenizer.json", "tokenizer.model", "tekken.json", "vocab.json", "merges.txt",
        ])
        let host = MockHostServices(pluginDataDirectory: fixture.root, defaults: ["loadedModel": modelID])
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        try await gate.withLock {
            let pending = await MainActor.run {
                if explicit {
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModelForModel:"), with: modelID as NSString)
                } else {
                    _ = plugin.perform(NSSelectorFromString("triggerRestoreModel"))
                }
                return task()
            }
            XCTAssertNotNil(pending)
            for _ in 0..<10 { await Task.yield() }
            try await plugin.deleteDownloadedModel(modelID)
            XCTAssertTrue(pending?.isCancelled == true, "Deletion must invalidate a load already waiting for its gate")
            XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
            XCTAssertNil(host.userDefault(forKey: "loadedModel"))
            pending?.cancel() // Keep the failing regression from ever attempting native/network loading.
            await pending?.value
        }
    }

    @MainActor
    func testFailedGenericRestorePreservesPersistedModelAcrossDeactivation() async throws {
        let qwen = Qwen3Plugin()
        try await assertRestorePersistence(qwen) { await qwen.restoreLoadedModel() }
    }

    @MainActor
    private func assertRestorePersistence<P: TranscriptionEnginePlugin & PluginSettingsActivityReporting>(
        _ plugin: P, restore: () async -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = try fixture.writeInvalidImportedModel()
        let host = MockHostServices(pluginDataDirectory: fixture.root, defaults: ["loadedModel": id])
        plugin.activate(host: host)
        await restore()
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertTrue(plugin.currentSettingsActivity?.isError == true, "Must reach the native loader")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, id)
        plugin.deactivate()
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, id)
    }

    @MainActor
    func testMLXCleanupStaysColdUntilAModelLoadEntersTheRuntime() async throws {
        let usages = [Qwen3Plugin.runtimeUsage]
        let previousUsages = usages.map { usage in usage.withLock { $0 } }
        defer {
            for (usage, previous) in zip(usages, previousUsages) { usage.withLock { $0 = previous } }
        }

        let qwen = Qwen3Plugin()
        try await assertCleanupStaysColdUntilRuntimeEntry(
            qwen, usage: Qwen3Plugin.runtimeUsage, cleanupTask: { qwen.runtimeCacheClearTask },
            unload: { qwen.unloadModel() }, load: { _ in await qwen.restoreLoadedModel() })
    }

    /// Unloading, deactivating and reactivating a never-loaded plugin must not
    /// schedule MLX cleanup. A load that fails after entering MLX must.
    @MainActor
    private func assertCleanupStaysColdUntilRuntimeEntry<P: TypeWhisperPlugin>(
        _ plugin: P,
        usage: OSAllocatedUnfairLock<Bool>,
        cleanupTask: () -> Task<Void, Never>?,
        unload: () -> Void,
        load: (Fixture) async throws -> Void
    ) async throws {
        usage.withLock { $0 = false }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = try fixture.writeInvalidImportedModel()
        let host = MockHostServices(pluginDataDirectory: fixture.root, defaults: ["loadedModel": id])

        plugin.activate(host: host)
        unload()
        plugin.deactivate()
        plugin.activate(host: host)
        plugin.deactivate()
        XCTAssertNil(cleanupTask(), "\(P.self) must not initialize Metal before any model load")
        XCTAssertFalse(usage.withLock { $0 })

        host.setUserDefault(id, forKey: "loadedModel")
        plugin.activate(host: host)
        try await load(fixture)
        XCTAssertTrue(usage.withLock { $0 }, "\(P.self) must record MLX use before the native loader runs")
        plugin.deactivate()
        let task = try XCTUnwrap(cleanupTask(), "\(P.self) must clear the cache after a failed load")
        await task.value
    }

    @MainActor
    private func assertExplicitLoadRequest<P: NSObject & TranscriptionEnginePlugin>(
        _ plugin: P, gate: PluginLocalInferenceGate, builtInID: String? = nil
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let modelID = builtInID ?? "custom-" + UUID().uuidString.lowercased()
        if builtInID == nil {
            let folder = fixture.root.appendingPathComponent("custom-models/" + modelID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let metadata: [String: Any] = [
                "id": modelID, "displayName": "Imported fixture", "modelType": "fixture",
                "origin": "fixture", "bytes": 0,
            ]
            try JSONSerialization.data(withJSONObject: metadata)
                .write(to: folder.appendingPathComponent("typewhisper-import.json"))
        }
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        plugin.activate(host: host)
        // Hold actual loading while checking the host's Objective-C entry point.
        // Deactivate before releasing the gate so this routing test never needs
        // real weights or a network download.
        try await gate.withLock {
            await MainActor.run {
                let selector = NSSelectorFromString("triggerRestoreModelForModel:")
                guard plugin.responds(to: selector) else {
                    XCTFail("Missing explicit model-load entry point")
                    plugin.deactivate()
                    return
                }
                XCTAssertNil(host.userDefault(forKey: "loadedModel"))
                _ = plugin.perform(selector, with: modelID as NSString)
                XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, modelID)
                plugin.deactivate()
            }
        }
    }

    func testModelCatalogsRecognizeLegacyAndCanonicalLayouts() throws {
        try assertCatalogRecognizesBothLayouts(
            plugin: Qwen3Plugin(),
            modelID: Qwen3Plugin.availableModels[0].id,
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"]
        )
    }

    func testActivationRemovesVerifiedDuplicateCopiesForAllPlugins() throws {
        try assertActivationRemovesDuplicate(
            plugin: Qwen3Plugin(),
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"],
            usesMLXAudio: true
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
    }

    func testPassiveOfflineRestoreDoesNotCreateDownloadArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let qwen = Qwen3Plugin.availableModels[0]
        let plugins: [(TypeWhisperPlugin, MockHostServices)] = [
            (Qwen3Plugin(), MockHostServices(
                pluginDataDirectory: fixture.root.appendingPathComponent("qwen"),
                defaults: ["loadedModel": qwen.id],
                shouldRestoreLoadedModelsPassively: true
            )),
        ]
        for (plugin, host) in plugins {
            plugin.activate(host: host)
        }

        try await Task.sleep(for: .milliseconds(100))

        for pluginRoot in ["qwen"] {
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

private final class SuspendedDownloadSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var requestedRequests: [URLRequest] {
        lock.withLock { requests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requests.append(request) }
        while true {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func finishTasksAndInvalidate() {}
}

private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
}

private final class MockHostServices: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    // The plugin's load task and the test read and write the defaults at the same time.
    private let defaultsLock = NSLock()
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
    func userDefault(forKey key: String) -> Any? { defaultsLock.withLock { defaults[key] } }
    func setUserDefault(_ value: Any?, forKey key: String) { defaultsLock.withLock { defaults[key] = value } }
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

    /// An imported model whose files pass the catalog checks but fail in the native loader.
    func writeInvalidImportedModel() throws -> String {
        let id = "custom-" + UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent("custom-models/" + id)
        try writeModel(at: folder, requiredFiles: [
            "config.json", "tokenizer.json", "tokenizer.model", "tekken.json", "vocab.json", "merges.txt",
        ])
        try write("invalid native config", to: folder.appendingPathComponent("config.json"))
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": id, "modelType": "fixture", "origin": id, "bytes": 0,
        ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        return id
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
