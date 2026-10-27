import Combine
import Foundation
import MLXLLM
import os
import SwiftUI
import XCTest
@testable import TypeWhisper
import TypeWhisperPluginSDK

final class MLXPluginModelStorageTests: XCTestCase {
    private let commit = String(repeating: "b", count: 40)
    /// Granite 4.0 follows `main` and has a legacy layout; the 5.0 models are pinned to a commit.
    private let graniteLegacyModel = GranitePlugin.availableModels.first { $0.id == "granite-1b-speech-4bit" }!

    @MainActor
    func testExplicitLoadHandlerAcceptsImportedModelIDs() async throws {
        let qwen = Qwen3Plugin()
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertExplicitLoadRequest(qwen, gate: qwen.modelLoadGate)
        try await assertExplicitLoadRequest(granite, gate: granite.modelLoadGate)
        try await assertExplicitLoadRequest(voxtral, gate: voxtral.modelLoadGate)
        try await assertExplicitLoadRequest(canary, gate: canary.modelLoadGate)
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

    func testGraniteAndVoxtralTranscriptionWaitsForSharedInferenceGate() async throws {
        let engines: [any TranscriptionEnginePlugin] = [GranitePlugin(), VoxtralPlugin()]
        for engine in engines {
            for streaming in [false, true] {
                try await PluginLocalInferenceGate.shared.withLock {
                    let transcription = Task {
                        let audio = AudioData(samples: [], wavData: Data(), duration: 0)
                        if streaming {
                            return try await engine.transcribe(audio: audio, language: "en", translate: false,
                                prompt: nil, onProgress: { _ in true })
                        }
                        return try await engine.transcribe(audio: audio, language: "en", translate: false, prompt: nil)
                    }
                    for _ in 0..<10 { await Task.yield() }
                    transcription.cancel()
                    do {
                        _ = try await transcription.value
                        XCTFail("Transcription must wait for the held inference gate")
                    } catch is CancellationError {
                        // The gate must reject cancellation before accessing the native runtime.
                    } catch {
                        XCTFail("Native runtime was accessed before acquiring the gate: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    private func assertSupersededExplicitRequests(allowFirstTaskToStart: Bool, selectionOnly: Bool = false) async throws {
        let qwen = Qwen3Plugin()
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertSupersededRequests(qwen, gate: qwen.modelLoadGate,
            allowFirstTaskToStart: allowFirstTaskToStart, selectionOnly: selectionOnly, currentTask: { qwen.explicitModelLoadTask })
        try await assertSupersededRequests(granite, gate: granite.modelLoadGate,
            allowFirstTaskToStart: allowFirstTaskToStart, selectionOnly: selectionOnly, currentTask: { granite.explicitModelLoadTask })
        try await assertSupersededRequests(voxtral, gate: voxtral.modelLoadGate,
            allowFirstTaskToStart: allowFirstTaskToStart, selectionOnly: selectionOnly, currentTask: { voxtral.explicitModelLoadTask })
        try await assertSupersededRequests(canary, gate: canary.modelLoadGate,
            allowFirstTaskToStart: allowFirstTaskToStart, selectionOnly: selectionOnly, currentTask: { canary.explicitModelLoadTask })
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
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertSupersededImport(qwen, gate: qwen.modelLoadGate)
        try await assertSupersededImport(granite, gate: granite.modelLoadGate)
        try await assertSupersededImport(voxtral, gate: voxtral.modelLoadGate)
        try await assertSupersededImport(canary, gate: canary.modelLoadGate)
    }

    @MainActor
    func testExplicitLoadInvalidatesPendingImportInEveryMLXEngine() async throws {
        let qwen = Qwen3Plugin()
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertSupersededImport(qwen, gate: qwen.modelLoadGate,
            replacementID: Qwen3Plugin.availableModels[0].id, currentTask: { qwen.explicitModelLoadTask })
        try await assertSupersededImport(granite, gate: granite.modelLoadGate,
            replacementID: graniteLegacyModel.id, currentTask: { granite.explicitModelLoadTask })
        try await assertSupersededImport(voxtral, gate: voxtral.modelLoadGate,
            replacementID: VoxtralPlugin.availableModels[0].id, currentTask: { voxtral.explicitModelLoadTask })
        try await assertSupersededImport(canary, gate: canary.modelLoadGate,
            replacementID: CanaryPlugin.availableModels[0].id, currentTask: { canary.explicitModelLoadTask })
    }

    @MainActor
    func testIncompleteImportsRemainRemovableInEveryMLXEngine() async throws {
        try await assertIncompleteImportIsRemovable(Qwen3Plugin())
        try await assertIncompleteImportIsRemovable(GranitePlugin())
        try await assertIncompleteImportIsRemovable(VoxtralPlugin())
        try await assertIncompleteImportIsRemovable(CanaryPlugin())
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
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertGenericRestoreIsSuperseded(qwen, gate: qwen.modelLoadGate,
            genericTask: { qwen.genericModelLoadTask }, explicitTask: { qwen.explicitModelLoadTask })
        try await assertGenericRestoreIsSuperseded(granite, gate: granite.modelLoadGate,
            genericTask: { granite.genericModelLoadTask }, explicitTask: { granite.explicitModelLoadTask })
        try await assertGenericRestoreIsSuperseded(voxtral, gate: voxtral.modelLoadGate,
            genericTask: { voxtral.genericModelLoadTask }, explicitTask: { voxtral.explicitModelLoadTask })
        try await assertGenericRestoreIsSuperseded(canary, gate: canary.modelLoadGate,
            genericTask: { canary.genericModelLoadTask }, explicitTask: { canary.explicitModelLoadTask })
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
    func testSelectingCachedModelStartsRestoreAndGenericRequestDoesNotCancelIt() async throws {
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertSelectionRestoresCachedModel(granite, gate: granite.modelLoadGate) { granite.genericModelLoadTask }
        try await assertSelectionRestoresCachedModel(voxtral, gate: voxtral.modelLoadGate) { voxtral.genericModelLoadTask }
        try await assertSelectionRestoresCachedModel(canary, gate: canary.modelLoadGate) { canary.genericModelLoadTask }
    }

    @MainActor
    private func assertSelectionRestoresCachedModel<P: NSObject & TranscriptionEnginePlugin & PluginSettingsActivityReporting>(
        _ plugin: P, gate: PluginLocalInferenceGate,
        task: @escaping @MainActor @Sendable () -> Task<Void, Never>?
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = "custom-" + UUID().uuidString.lowercased()
        let folder = fixture.root.appendingPathComponent("custom-models/" + id)
        try fixture.writeModel(at: folder, requiredFiles: [
            "config.json", "tokenizer.json", "tokenizer.model", "tekken.json", "vocab.json", "merges.txt",
        ])
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": id, "modelType": "fixture", "origin": id, "bytes": 0,
        ]).write(to: folder.appendingPathComponent("typewhisper-import.json"))
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        try await gate.withLock {
            let pending = await MainActor.run {
                plugin.selectModel(id)
                let pending = task()
                XCTAssertNotNil(pending, "Restoring an override selection must start loading its cached model")
                XCTAssertNotNil(plugin.currentSettingsActivity)
                _ = plugin.perform(NSSelectorFromString("triggerRestoreModel"))
                XCTAssertFalse(pending?.isCancelled ?? true, "Generic restore must preserve the selection restore")
                plugin.deactivate()
                XCTAssertTrue(pending?.isCancelled == true)
                return pending
            }
            await pending?.value
        }
    }

    @MainActor
    func testDeletingModelCancelsQueuedExplicitAndGenericLoads() async throws {
        for explicit in [true, false] {
            let qwen = Qwen3Plugin()
            let granite = GranitePlugin()
            let voxtral = VoxtralPlugin()
            let canary = CanaryPlugin()
            try await assertDeletionCancelsQueuedLoad(qwen, gate: qwen.modelLoadGate, explicit: explicit,
                modelID: Qwen3Plugin.availableModels[0].id, repositoryID: Qwen3Plugin.availableModels[0].repoId,
                task: { explicit ? qwen.explicitModelLoadTask : qwen.genericModelLoadTask })
            try await assertDeletionCancelsQueuedLoad(granite, gate: granite.modelLoadGate, explicit: explicit,
                modelID: graniteLegacyModel.id, repositoryID: graniteLegacyModel.repoId,
                task: { explicit ? granite.explicitModelLoadTask : granite.genericModelLoadTask })
            try await assertDeletionCancelsQueuedLoad(voxtral, gate: voxtral.modelLoadGate, explicit: explicit,
                modelID: VoxtralPlugin.availableModels[0].id, repositoryID: VoxtralPlugin.availableModels[0].repoId,
                task: { explicit ? voxtral.explicitModelLoadTask : voxtral.genericModelLoadTask })
            try await assertDeletionCancelsQueuedLoad(canary, gate: canary.modelLoadGate, explicit: explicit,
                modelID: CanaryPlugin.availableModels[0].id, repositoryID: CanaryPlugin.availableModels[0].repoId,
                task: { explicit ? canary.explicitModelLoadTask : canary.genericModelLoadTask })
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
        let granite = GranitePlugin()
        let voxtral = VoxtralPlugin()
        let canary = CanaryPlugin()
        try await assertRestorePersistence(qwen) { await qwen.restoreLoadedModel() }
        try await assertRestorePersistence(granite) { await granite.restoreLoadedModel() }
        try await assertRestorePersistence(voxtral) { await voxtral.restoreLoadedModel() }
        try await assertRestorePersistence(canary) { await canary.restoreLoadedModel() }
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
        let usages = [Qwen3Plugin.runtimeUsage, CanaryPlugin.runtimeUsage, LocalLLMPlugin.runtimeUsage]
        let previousUsages = usages.map { usage in usage.withLock { $0 } }
        defer {
            for (usage, previous) in zip(usages, previousUsages) { usage.withLock { $0 = previous } }
        }

        let qwen = Qwen3Plugin()
        try await assertCleanupStaysColdUntilRuntimeEntry(
            qwen, usage: Qwen3Plugin.runtimeUsage, cleanupTask: { qwen.runtimeCacheClearTask },
            unload: { qwen.unloadModel() }, load: { _ in await qwen.restoreLoadedModel() })
        let canary = CanaryPlugin()
        try await assertCleanupStaysColdUntilRuntimeEntry(
            canary, usage: CanaryPlugin.runtimeUsage, cleanupTask: { canary.runtimeCacheClearTask },
            unload: { canary.unloadModel() }, load: { _ in await canary.restoreLoadedModel() })

        let gemma = LocalLLMPlugin()
        let gemmaModel = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        try await assertCleanupStaysColdUntilRuntimeEntry(
            gemma, usage: LocalLLMPlugin.runtimeUsage, cleanupTask: { gemma.runtimeCacheClearTask },
            unload: {
                gemma.unloadModel()
                gemma.resetCachedModel(gemmaModel)
            },
            load: { fixture in
                try fixture.writeModel(
                    at: fixture.legacyDirectory(repositoryID: gemmaModel.repoId, usesMLXAudio: false),
                    requiredFiles: ["config.json", "tokenizer.json"]
                )
                do {
                    try await gemma.loadModel(gemmaModel)
                    XCTFail("Fixture weights must not load")
                } catch {}
            })
    }

    @MainActor
    func testLocalLLMLoadThatStopsBeforeMLXKeepsCleanupCold() async throws {
        let previousUsage = LocalLLMPlugin.runtimeUsage.withLock { $0 }
        LocalLLMPlugin.runtimeUsage.withLock { $0 = false }
        defer { LocalLLMPlugin.runtimeUsage.withLock { $0 = previousUsage } }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gemma = LocalLLMPlugin()
        gemma.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        // The downloader rejects this repository ID offline, before any MLX work.
        let undownloadable = LocalLLMModelDef(
            id: "fixture-undownloadable", displayName: "Fixture", repoId: "not-a-repository",
            sizeDescription: "", minimumMemoryGB: 8, availability: .supported)

        do {
            try await gemma.loadModel(undownloadable)
            XCTFail("An invalid repository must not load")
        } catch {}
        XCTAssertFalse(LocalLLMPlugin.runtimeUsage.withLock { $0 }, "A failed download must not count as MLX use")
        gemma.unloadModel()
        gemma.deactivate()
        XCTAssertNil(gemma.runtimeCacheClearTask, "Cleanup must stay cold when the load stopped before MLX")
    }

    @MainActor
    func testLocalLLMRefusesAModelDownloadTheHostDoesNotAllow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reason = "Your organization does not allow model downloads."
        let gemma = LocalLLMPlugin()
        gemma.activate(host: MockHostServices(pluginDataDirectory: fixture.root, modelDownloadRefusal: reason))
        let model = LocalLLMModelDef(
            id: "fixture-refused", displayName: "Fixture", repoId: "mlx-community/fixture-refused",
            sizeDescription: "", minimumMemoryGB: 8, availability: .supported)

        do {
            try await gemma.loadModel(model)
            XCTFail("A refused download must not load")
        } catch {
            XCTAssertEqual(error as? PluginModelDownloadRefusedError, PluginModelDownloadRefusedError(reason: reason))
        }
        XCTAssertEqual(gemma.modelState, .error(reason))
        gemma.unloadModel()
        gemma.deactivate()
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
    func testFreshCanaryAcceptsExplicitBuiltInLoadWithoutPersistedLoadedModel() async throws {
        let canary = CanaryPlugin()
        try await assertExplicitLoadRequest(
            canary, gate: canary.modelLoadGate, builtInID: CanaryPlugin.availableModels[0].id)
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

    func testGemma4SourceAvoidsSDKSymbolsUnavailableInHost16() throws {
        let pluginDirectory = TestSupport.repoRoot.appendingPathComponent(
            "TypeWhisperPluginSDK/Plugins/LocalLLMPlugin"
        )
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("PluginHTTPClient.ensureNetworkAccessIsAllowed"),
                "\(sourceURL.lastPathComponent) must remain loadable by the declared TypeWhisper 1.6.0 host"
            )
        }
    }

    func testGemma4PromptKeepsInstructionsOutOfTheUserTurn() {
        let messages = LocalLLMPlugin.promptMessages(
            systemPrompt: "Translate the following text to English.",
            userText: "Hallo Welt"
        )

        XCTAssertEqual(messages.map(\.role), [.system, .user])
        XCTAssertEqual(messages.map(\.content), ["Translate the following text to English.", "Hallo Welt"])
    }

    func testLocalLLMRecommendationFollowsInstalledMemory() {
        let recommendations = [4, 8, 16, 24, 32, 48, 64].map {
            LocalLLMPlugin.recommendedModel(forMemoryGB: $0)?.id
        }

        XCTAssertEqual(recommendations, [
            "gemma-4-e2b-it-4bit",
            "gemma-4-e2b-it-4bit",
            "gemma-4-e4b-it-4bit",
            "gemma-4-e4b-it-4bit",
            "gemma-4-e4b-it-4bit",
            "gemma-4-e4b-it-4bit",
            "gemma-4-e4b-it-4bit",
        ])
    }

    func testGemma4NetworkPolicyAllowsNormalRuntime() {
        XCTAssertNoThrow(
            try LocalLLMNetworkAccessPolicy.ensureAccessIsAllowed(arguments: ["TypeWhisper"])
        )
    }

    func testGemma4NetworkPolicyBlocksScreenshotAutomation() {
        XCTAssertThrowsError(
            try LocalLLMNetworkAccessPolicy.ensureAccessIsAllowed(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testGemma4LLMRuntimeAcceptsCurrentAndLegacyConfigurationTypes() async throws {
        for modelType in ["gemma4", "gemma4_text", "gemma4_unified"] {
            let isRegistered = await LLMTypeRegistry.shared.contains(modelType)
            XCTAssertTrue(isRegistered, "Missing Gemma 4 LLM model type: \(modelType)")
        }

        let configurations = [
            """
            {
              "model_type": "gemma4",
              "vocab_size": 262144,
              "text_config": { "model_type": "gemma4_text" },
              "audio_config": { "model_type": "gemma4_audio" },
              "vision_config": { "model_type": "gemma4_vision" }
            }
            """,
            """
            {
              "model_type": "gemma4_unified",
              "vocab_size": 262144,
              "text_config": { "model_type": "gemma4_unified_text" },
              "audio_config": { "model_type": "gemma4_unified_audio" },
              "vision_config": { "model_type": "gemma4_unified_vision" }
            }
            """,
        ]

        for configuration in configurations {
            XCTAssertNoThrow(
                try JSONDecoder().decode(
                    Gemma4Configuration.self,
                    from: Data(configuration.utf8)
                )
            )
        }
    }

    @MainActor
    func testLocalLLMCachedLoadRestoreAndDeletionPublishOnMainThread() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e4b-it-4bit"))
        let directory = fixture.legacyDirectory(repositoryID: model.repoId, usesMLXAudio: false)
        try fixture.writeMinimalGemmaModel(at: directory)
        let host = MockHostServices(pluginDataDirectory: fixture.root)
        let plugin = LocalLLMPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let publications = LocalLLMPublicationRecorder(plugin: plugin)

        // Match Settings: an observed plugin loads an already downloaded model.
        let settings = NSHostingView(rootView: LocalLLMSettingsView(plugin: plugin))
        settings.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        settings.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(settings) {} }
        XCTAssertTrue(plugin.isModelDownloaded(model))
        try await plugin.loadModel(model)
        XCTAssertEqual(plugin.modelState, .ready(model.id))
        XCTAssertTrue(plugin.isAvailable)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, model.id)
        XCTAssertEqual(publications.backgroundPublications, [])

        plugin.unloadModel(clearPersistence: false)
        await Task.detached {
            await plugin.restoreLoadedModel(allowDownloads: false)
        }.value
        XCTAssertEqual(plugin.modelState, .ready(model.id))
        XCTAssertTrue(plugin.isAvailable)
        XCTAssertEqual(publications.backgroundPublications, [])

        // The host can invoke the asynchronous SDK capability from any executor.
        let manager: any PluginDownloadedModelManaging = plugin
        try await Task.detached {
            try await manager.deleteDownloadedModel(model.id)
        }.value
        XCTAssertEqual(plugin.modelState, .notLoaded)
        XCTAssertFalse(plugin.isModelDownloaded(model))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(publications.backgroundPublications, [])
        XCTAssertGreaterThan(publications.count, 0)
    }

    @MainActor
    func testLocalLLMCachedLoadFailurePublishesOnMainThread() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e4b-it-4bit"))
        let directory = fixture.legacyDirectory(repositoryID: model.repoId, usesMLXAudio: false)
        try fixture.writeModel(at: directory, requiredFiles: ["config.json", "tokenizer.json"])
        try fixture.write("invalid config", to: directory.appendingPathComponent("config.json"))
        let plugin = LocalLLMPlugin()
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        defer { plugin.deactivate() }
        let publications = LocalLLMPublicationRecorder(plugin: plugin)

        XCTAssertTrue(plugin.isModelDownloaded(model))
        do {
            try await plugin.loadModel(model)
            XCTFail("Invalid cached configuration must fail to load")
        } catch {
            guard case .error = plugin.modelState else {
                return XCTFail("The load failure must be visible in Settings")
            }
        }
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertEqual(publications.backgroundPublications, [])
        XCTAssertGreaterThan(publications.count, 0)
    }

    @MainActor
    func testLocalLLMLoadWatchdogPublishesOnMainThread() async throws {
        let plugin = LocalLLMPlugin()
        defer { plugin.deactivate() }
        let publications = LocalLLMPublicationRecorder(plugin: plugin)
        plugin.setModelLoadTimeoutForTesting(.milliseconds(10))
        plugin.startModelLoadTimeoutForTesting(modelName: "Gemma 4 E4B")

        let deadline = ContinuousClock.now + .seconds(2)
        while plugin.modelState == .downloading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .error = plugin.modelState else {
            return XCTFail("The stalled load must time out")
        }
        XCTAssertEqual(publications.backgroundPublications, [])
        XCTAssertGreaterThan(publications.count, 0)
    }

    func testModelCatalogsRecognizeLegacyAndCanonicalLayouts() throws {
        try assertCatalogRecognizesBothLayouts(
            plugin: Qwen3Plugin(),
            modelID: Qwen3Plugin.availableModels[0].id,
            repositoryID: Qwen3Plugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "vocab.json", "merges.txt"]
        )
        try assertCatalogRecognizesBothLayouts(
            plugin: GranitePlugin(),
            modelID: graniteLegacyModel.id,
            repositoryID: graniteLegacyModel.repoId,
            requiredFiles: ["config.json", "tokenizer.json"]
        )
        try assertCatalogRecognizesBothLayouts(
            plugin: VoxtralPlugin(),
            modelID: VoxtralPlugin.availableModels[0].id,
            repositoryID: VoxtralPlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tekken.json"]
        )

        let gemmaModel = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        let gemmaFixture = try Fixture()
        defer { gemmaFixture.remove() }
        let gemmaHost = MockHostServices(pluginDataDirectory: gemmaFixture.root)
        let gemma = LocalLLMPlugin()
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

    func testGraniteRecognizesPinnedSnapshotsWithoutARef() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plugin = GranitePlugin()
        plugin.activate(host: MockHostServices(pluginDataDirectory: fixture.root))
        let model = try XCTUnwrap(GranitePlugin.availableModels.first { $0.id == "granite-speech-5.0-470m-turboctc" })
        let revision = try XCTUnwrap(model.revision)
        // A download pinned to a commit writes the snapshot but no refs/ entry.
        let snapshot = fixture.repositoryDirectory(repositoryID: model.repoId)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try fixture.writeModel(at: snapshot, requiredFiles: ["config.json", "tokenizer.json"])
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])

        // Another commit of the same repository is not the pinned model.
        try FileManager.default.moveItem(
            at: snapshot,
            to: snapshot.deletingLastPathComponent().appendingPathComponent(commit, isDirectory: true)
        )
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [])
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
            repositoryID: graniteLegacyModel.repoId,
            requiredFiles: ["config.json", "tokenizer.json"],
            usesMLXAudio: true
        )
        try assertActivationRemovesDuplicate(
            plugin: VoxtralPlugin(),
            repositoryID: VoxtralPlugin.availableModels[0].repoId,
            requiredFiles: ["config.json", "tekken.json"],
            usesMLXAudio: true
        )

        let model = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        try assertActivationRemovesDuplicate(
            plugin: LocalLLMPlugin(),
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
            modelID: graniteLegacyModel.id,
            repositoryID: graniteLegacyModel.repoId,
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

        let model = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
        try await assertDeletionRemovesAllArtifacts(
            plugin: LocalLLMPlugin(),
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
        let granite = graniteLegacyModel
        let voxtral = VoxtralPlugin.availableModels[0]
        let gemma = try XCTUnwrap(LocalLLMPlugin.modelDefinition(for: "gemma-4-e2b-it-4bit"))
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
            (LocalLLMPlugin(), MockHostServices(
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

/// Observe synchronously, like SwiftUI. Scheduling reception on main would hide
/// the offending publication; Sendable sinks let us record it instead of trapping.
private final class LocalLLMPublicationRecorder {
    private let events = OSAllocatedUnfairLock(initialState: [(name: String, isMainThread: Bool)]())
    private var subscriptions: [AnyCancellable] = []

    init(plugin: LocalLLMPlugin) {
        let events = self.events
        subscriptions = [
            plugin.objectWillChange.sink { @Sendable _ in
                events.withLock { $0.append(("objectWillChange", Thread.isMainThread)) }
            },
            plugin.$modelState.dropFirst().sink { @Sendable state in
                events.withLock { $0.append(("modelState: \(state)", Thread.isMainThread)) }
            },
            plugin.$downloadProgress.dropFirst().sink { @Sendable _ in
                events.withLock { $0.append(("downloadProgress", Thread.isMainThread)) }
            },
        ]
    }

    var count: Int { events.withLock { $0.count } }
    var backgroundPublications: [String] {
        events.withLock { $0.filter { !$0.isMainThread }.map(\.name) }
    }
}

private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
}

private final class MockHostServices: HostServices, HostModelLifecyclePolicyProviding, HostManagedPolicyProviding, @unchecked Sendable {
    // The plugin's load task and the test read and write the defaults at the same time.
    private let defaultsLock = NSLock()
    private var defaults: [String: Any]

    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol = MockEventBus()
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let availableRuleNames: [String] = []
    let shouldRestoreLoadedModelsPassively: Bool
    let modelDownloadRefusal: String?

    init(
        pluginDataDirectory: URL,
        defaults: [String: Any] = [:],
        shouldRestoreLoadedModelsPassively: Bool = false,
        modelDownloadRefusal: String? = nil
    ) {
        self.pluginDataDirectory = pluginDataDirectory
        self.defaults = defaults
        self.shouldRestoreLoadedModelsPassively = shouldRestoreLoadedModelsPassively
        self.modelDownloadRefusal = modelDownloadRefusal
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

    /// Tiny native Gemma checkpoint: exercises the real loader without a download
    /// or multi-gigabyte model. No transformer layers are needed to test loading.
    func writeMinimalGemmaModel(at directory: URL) throws {
        try write("""
        {"model_type":"gemma4","vocab_size":16,"text_config":{
          "hidden_size":16,"num_hidden_layers":0,"num_kv_shared_layers":0,
          "hidden_size_per_layer_input":0,"vocab_size":16,"tie_word_embeddings":true
        }}
        """, to: directory.appendingPathComponent("config.json"))
        try write("""
        {"tokenizer_class":"PreTrainedTokenizerFast","unk_token":"<unk>"}
        """, to: directory.appendingPathComponent("tokenizer_config.json"))
        try write("""
        {"model":{"type":"BPE","vocab":{"<unk>":0,"hello":1},"merges":[]},"added_tokens":[]}
        """, to: directory.appendingPathComponent("tokenizer.json"))
        let header = try JSONSerialization.data(withJSONObject: [
            "language_model.model.embed_tokens.weight": [
                "dtype": "F32", "shape": [16, 16], "data_offsets": [0, 1024],
            ],
            "language_model.model.norm.weight": [
                "dtype": "F32", "shape": [16], "data_offsets": [1024, 1088],
            ],
        ])
        var length = UInt64(header.count).littleEndian
        var weights = withUnsafeBytes(of: &length) { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 1088))
        try weights.write(to: directory.appendingPathComponent("model.safetensors"))
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
