import XCTest
@testable import TypeWhisperPluginSDK

final class TransientModelSelectionTests: XCTestCase {
    func testBeginChangesTheRevisionOnlyForANewModel() {
        let selection = PluginTransientModelSelection()
        XCTAssertNil(selection.modelId)
        let initial = selection.revision

        XCTAssertTrue(selection.begin("large"))
        XCTAssertEqual(selection.modelId, "large")
        let afterBegin = selection.revision
        XCTAssertNotEqual(afterBegin, initial)

        XCTAssertFalse(selection.begin("large"), "The same model is already in use")
        XCTAssertEqual(selection.revision, afterBegin)

        XCTAssertTrue(selection.begin("small"))
        XCTAssertEqual(selection.modelId, "small")
        XCTAssertNotEqual(selection.revision, afterBegin)
    }

    func testEndReturnsTheEndedModelOnce() {
        let selection = PluginTransientModelSelection()
        let initial = selection.revision
        XCTAssertNil(selection.end(), "Nothing to end")
        XCTAssertEqual(selection.revision, initial, "Ending nothing changes nothing")

        selection.begin("large")
        XCTAssertEqual(selection.end(), "large")
        XCTAssertNil(selection.modelId)
        XCTAssertNil(selection.end())
    }

    func testOnlyTheTransientModelMayBeUsedWhileItLasts() {
        let selection = PluginTransientModelSelection()
        let beforeBegin = selection.revision

        selection.begin("large")

        XCTAssertFalse(selection.permitsLoad(of: "small", requestedAt: beforeBegin), "The user's model loaded before the selection began")
        XCTAssertTrue(selection.permitsLoad(of: "large", requestedAt: beforeBegin), "The transient model itself stays usable")
        XCTAssertFalse(selection.permitsLoad(of: "small", requestedAt: selection.revision))
    }

    func testLoadsRequestedBeforeTheSelectionEndedAreStale() {
        let selection = PluginTransientModelSelection()
        selection.begin("large")
        let duringSelection = selection.revision

        selection.end()

        XCTAssertFalse(selection.permitsLoad(of: "large", requestedAt: duringSelection))
        XCTAssertFalse(selection.permitsLoad(of: "small", requestedAt: duringSelection))
        XCTAssertTrue(selection.permitsLoad(of: "small", requestedAt: selection.revision))
    }

    func testInstallRunsOnlyForAPermittedLoadAndReportsTransientModels() {
        let selection = PluginTransientModelSelection()
        var installed: [(String, Bool)] = []
        let beforeBegin = selection.revision

        XCTAssertTrue(selection.installIfPermitted("small", requestedAt: beforeBegin) { installed.append(("small", $0)) })
        selection.begin("large")
        XCTAssertFalse(selection.installIfPermitted("small", requestedAt: beforeBegin) { installed.append(("small", $0)) })
        XCTAssertTrue(selection.installIfPermitted("large", requestedAt: beforeBegin) { installed.append(("large", $0)) })
        let duringSelection = selection.revision
        selection.end()
        XCTAssertFalse(selection.installIfPermitted("large", requestedAt: duringSelection) { installed.append(("large", $0)) })

        XCTAssertEqual(installed.map(\.0), ["small", "large"])
        XCTAssertEqual(installed.map(\.1), [false, true], "Only the transient model is reported as transient")
    }

    func testSelectionCannotEndWhileAModelIsInstalled() async {
        let selection = PluginTransientModelSelection()
        selection.begin("large")
        let revision = selection.revision
        let installing = expectation(description: "install started")
        let release = DispatchSemaphore(value: 0)
        let ended = expectation(description: "selection ended")
        let order = OrderRecorder()

        let installer = Thread {
            selection.installIfPermitted("large", requestedAt: revision) { _ in
                installing.fulfill()
                release.wait()
                order.append("installed")
            }
        }
        installer.start()
        await fulfillment(of: [installing], timeout: 2)
        let ender = Thread {
            selection.end()
            order.append("ended")
            ended.fulfill()
        }
        ender.start()
        release.signal()
        await fulfillment(of: [ended], timeout: 2)

        XCTAssertEqual(order.values, ["installed", "ended"])
    }

    func testLoadsWithoutATransientSelectionAreUnaffected() {
        let selection = PluginTransientModelSelection()
        let revision = selection.revision

        XCTAssertTrue(selection.permitsLoad(of: "small", requestedAt: revision))
        XCTAssertTrue(selection.permitsLoad(of: "large", requestedAt: revision))
    }

    func testConcurrentChangesKeepAConsistentState() async {
        let selection = PluginTransientModelSelection()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        selection.begin(index.isMultiple(of: 4) ? "large" : "small")
                    } else {
                        selection.end()
                    }
                    _ = selection.permitsLoad(of: "large", requestedAt: selection.revision)
                }
            }
        }
        if let modelId = selection.modelId {
            XCTAssertTrue(["large", "small"].contains(modelId))
            XCTAssertTrue(selection.permitsLoad(of: modelId, requestedAt: 0))
        } else {
            XCTAssertTrue(selection.permitsLoad(of: "large", requestedAt: selection.revision))
        }
    }

    func testTransientModelSelectionProtocolIsOptional() {
        let legacy = LegacyEngine()
        let adopting = TransientEngine()

        XCTAssertFalse((legacy as Any) is any TransientModelSelectionProviding)
        XCTAssertTrue((adopting as Any) is any TransientModelSelectionProviding)

        adopting.selectModel("small")
        adopting.beginTransientModelSelection("large")
        XCTAssertEqual(adopting.selectedModelId, "large")
        XCTAssertEqual(adopting.transientModelId, "large")
        adopting.beginTransientModelSelection("missing")
        XCTAssertEqual(adopting.transientModelId, "large", "Unknown models are ignored")

        adopting.endTransientModelSelection()
        XCTAssertEqual(adopting.selectedModelId, "small")
        XCTAssertNil(adopting.transientModelId)
    }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.withLock { recorded.append(value) }
    }

    var values: [String] {
        lock.withLock { recorded }
    }
}

private class EngineBase: NSObject, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.transient"
    static let pluginName = "Transient"

    var savedModelId: String?

    required override init() {}

    var providerId: String { "transient" }
    var providerDisplayName: String { "Transient" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] {
        ["small", "large"].map { PluginModelInfo(id: $0, displayName: $0) }
    }
    var supportsTranslation: Bool { false }
    func activate(host: HostServices) {}
    func deactivate() {}
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok")
    }
}

private final class LegacyEngine: EngineBase, TranscriptionEnginePlugin, @unchecked Sendable {
    var selectedModelId: String? { savedModelId }
    func selectModel(_ modelId: String) { savedModelId = modelId }
}

private final class TransientEngine: EngineBase, TransientModelSelectionProviding, @unchecked Sendable {
    private let transient = PluginTransientModelSelection()

    var selectedModelId: String? { transient.modelId ?? savedModelId }
    var transientModelId: String? { transient.modelId }
    func selectModel(_ modelId: String) { savedModelId = modelId }

    func beginTransientModelSelection(_ modelId: String) {
        guard transcriptionModels.contains(where: { $0.id == modelId }) else { return }
        transient.begin(modelId)
    }

    func endTransientModelSelection() {
        transient.end()
    }
}
