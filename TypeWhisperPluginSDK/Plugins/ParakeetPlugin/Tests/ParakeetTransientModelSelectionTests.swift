import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ParakeetPlugin

/// A transient selection is how TypeWhisper applies a model that managed settings enforce:
/// the model is used without being saved, and ending it returns to the user's selection.
final class ParakeetTransientModelSelectionTests: XCTestCase {
    private let v2 = "parakeet-tdt-0.6b-v2"
    private let v3 = "parakeet-tdt-0.6b-v3"

    /// Records model loads; a load can be held until released.
    private actor LoadRecorder {
        private(set) var versions: [String] = []
        private var holdsNextLoad = false
        private var release: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?

        func holdNextLoad() { holdsNextLoad = true }

        func load(_ modelId: String) async {
            versions.append(modelId)
            startWaiter?.resume()
            startWaiter = nil
            if holdsNextLoad {
                holdsNextLoad = false
                await withCheckedContinuation { release = $0 }
            }
        }

        func waitForStart() async {
            guard versions.isEmpty else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func releaseLoad() {
            release?.resume()
            release = nil
        }
    }

    private func makePlugin(
        defaults: [String: Any] = [:],
        recorder: LoadRecorder
    ) throws -> (ParakeetPlugin, PluginTestHostServices) {
        // Passive restores load installed files, which differ between Macs; they stay off here.
        let host = try PluginTestHostServices(defaults: defaults, shouldRestoreLoadedModelsPassively: false)
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = false
        plugin.asrModelLoadOverrideForTests = { version in await recorder.load(version.modelDef.id) }
        plugin.activate(host: host)
        addTeardownBlock { plugin.deactivate() }
        return (plugin, host)
    }

    private func savedState(_ host: PluginTestHostServices) -> [String?] {
        ["selectedModel", "loadedModel", "selectedVersion"].map { host.userDefault(forKey: $0) as? String }
    }

    func testTransientModelIsUsedWithoutBeingSavedAndEndsAtTheUsersModel() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(
            defaults: ["selectedModel": v2, "loadedModel": v2, "selectedVersion": "v2"],
            recorder: recorder
        )
        await plugin.restoreLoadedModel()
        XCTAssertEqual(plugin.loadedModelId, v2)
        let saved = savedState(host)

        plugin.beginTransientModelSelection(v3)

        XCTAssertEqual(plugin.selectedModelId, v3)
        XCTAssertEqual(plugin.transientModelId, v3)
        XCTAssertEqual(plugin.supportedLanguages, ParakeetVersion.v3.supportedLanguages)
        XCTAssertFalse(plugin.isConfigured, "The user's model is unloaded so it is not used")

        // First use restores the model in use, which is the transient one.
        await plugin.restoreLoadedModel()
        XCTAssertEqual(plugin.loadedModelId, v3)
        XCTAssertEqual(savedState(host), saved, "Nothing about the transient model is saved")

        plugin.endTransientModelSelection()

        XCTAssertNil(plugin.transientModelId)
        XCTAssertEqual(plugin.selectedModelId, v2)
        XCTAssertEqual(plugin.supportedLanguages, ParakeetVersion.v2.supportedLanguages)
        XCTAssertFalse(plugin.isConfigured, "The transient model does not stay loaded")
        XCTAssertEqual(savedState(host), saved)
        let versions = await recorder.versions
        XCTAssertEqual(versions, [v2, v3], "Beginning and ending load nothing by themselves")
    }

    func testEndingReturnsToNoSelection() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(recorder: recorder)
        XCTAssertNil(plugin.selectedModelId)

        plugin.beginTransientModelSelection(v3)
        await plugin.restoreLoadedModel()
        XCTAssertTrue(plugin.isConfigured)

        plugin.endTransientModelSelection()

        XCTAssertNil(plugin.selectedModelId)
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(savedState(host), [nil, nil, nil])
    }

    func testUserModelAlsoInUseStaysLoaded() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(
            defaults: ["selectedModel": v3, "loadedModel": v3, "selectedVersion": "v3"],
            recorder: recorder
        )
        await plugin.restoreLoadedModel()

        plugin.beginTransientModelSelection(v3)
        XCTAssertTrue(plugin.isConfigured, "The enforced model is already the loaded one")
        plugin.endTransientModelSelection()

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, v3)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, v3)
        let versions = await recorder.versions
        XCTAssertEqual(versions, [v3])
    }

    func testChoicesDuringTheTransientSelectionAreSavedForLater() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(recorder: recorder)
        plugin.beginTransientModelSelection(v3)

        plugin.selectModel(v2)
        XCTAssertEqual(plugin.selectedModelId, v3)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, v2)

        plugin.suppressAsyncRestoreForTests = true
        plugin.triggerRestoreModel(forModel: v2 as NSString)
        await plugin.loadModel(version: .v2)
        XCTAssertEqual(plugin.selectedModelId, v3)
        XCTAssertFalse(plugin.isConfigured, "Another model is not loaded while the transient one is in use")

        plugin.endTransientModelSelection()

        XCTAssertEqual(plugin.selectedModelId, v2)
        XCTAssertEqual(host.userDefault(forKey: "selectedVersion") as? String, "v2")
        let versions = await recorder.versions
        XCTAssertEqual(versions, [])
    }

    func testUserModelLoadingWhenTheTransientSelectionBeginsIsDiscarded() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(
            defaults: ["selectedModel": v2, "loadedModel": v2, "selectedVersion": "v2"],
            recorder: recorder
        )
        await recorder.holdNextLoad()
        let restore = Task { await plugin.restoreLoadedModel() }
        await recorder.waitForStart()

        plugin.beginTransientModelSelection(v3)
        await recorder.releaseLoad()
        await restore.value

        XCTAssertFalse(plugin.isConfigured, "The user's model must not replace the transient one")
        XCTAssertNil(plugin.loadedModelId)
        XCTAssertEqual(plugin.selectedModelId, v3)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, v2)
    }

    func testTransientModelLoadingWhenTheSelectionEndsIsDiscarded() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(recorder: recorder)
        plugin.beginTransientModelSelection(v3)
        await recorder.holdNextLoad()
        let restore = Task { await plugin.restoreLoadedModel() }
        await recorder.waitForStart()

        plugin.endTransientModelSelection()
        await recorder.releaseLoad()
        await restore.value

        XCTAssertFalse(plugin.isConfigured, "The transient model must not stay in use")
        XCTAssertNil(plugin.selectedModelId)
        XCTAssertEqual(savedState(host), [nil, nil, nil], "Nothing enforced is saved")
    }

    func testChangingTheTransientModelReplacesIt() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(recorder: recorder)
        plugin.beginTransientModelSelection(v3)
        await plugin.restoreLoadedModel()

        plugin.beginTransientModelSelection(v2)

        XCTAssertEqual(plugin.selectedModelId, v2)
        XCTAssertFalse(plugin.isConfigured, "The previous transient model is unloaded")
        await plugin.restoreLoadedModel()
        XCTAssertEqual(plugin.loadedModelId, v2)
        XCTAssertEqual(savedState(host), [nil, nil, nil])
    }

    func testDeactivationDropsTheTransientSelection() throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(defaults: ["selectedModel": v2], recorder: recorder)
        plugin.beginTransientModelSelection(v3)

        plugin.deactivate()
        plugin.activate(host: host)

        XCTAssertNil(plugin.transientModelId)
        XCTAssertEqual(plugin.selectedModelId, v2)
    }

    func testUnknownModelsAreIgnored() throws {
        let recorder = LoadRecorder()
        let (plugin, _) = try makePlugin(defaults: ["selectedModel": v2], recorder: recorder)

        plugin.beginTransientModelSelection("whisper-large")
        plugin.endTransientModelSelection()

        XCTAssertNil(plugin.transientModelId)
        XCTAssertEqual(plugin.selectedModelId, v2)
    }

    func testUnloadDuringTheTransientSelectionKeepsTheUsersModelToRestore() async throws {
        let recorder = LoadRecorder()
        let (plugin, host) = try makePlugin(
            defaults: ["selectedModel": v2, "loadedModel": v2, "selectedVersion": "v2"],
            recorder: recorder
        )
        plugin.beginTransientModelSelection(v3)
        await plugin.restoreLoadedModel()

        plugin.unloadModel()

        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, v2)
    }
}
