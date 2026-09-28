import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Regression tests for https://github.com/TypeWhisper/typewhisper-mac/issues/840.
///
/// After the auto-unload timer releases a local model, the next dictation must
/// restore the persisted model and proceed instead of throwing `modelNotLoaded`.
/// The host only extends its restore wait past the base window while the plugin
/// reports a settings activity, so a plugin whose restore task is slow to start
/// (cold CoreML compile) must publish its restore activity synchronously from
/// `triggerRestoreModel()`.
@MainActor
final class ModelManagerRestoreAfterAutoUnloadTests: XCTestCase {
    override func tearDown() {
        PluginManager.shared = nil
        super.tearDown()
    }

    func testTranscribeRestoresAutoUnloadedEngineInsteadOfThrowingModelNotLoaded() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        // The restore takes longer than the base wait window but publishes its
        // activity synchronously, like ParakeetPlugin does after the #840 fix.
        // The host must extend its wait and let the restore finish.
        let plugin = RestoreAfterUnloadMockPlugin(
            configured: false,
            restoreResult: .succeedAfter(.milliseconds(300)),
            publishesActivitySynchronously: true
        )
        let modelManager = installPlugin(plugin, appSupportDirectory: appSupportDirectory)
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 2,
            busyAttempts: 200,
            pollInterval: .milliseconds(50)
        )

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 1_600),
            language: nil,
            task: .transcribe
        )

        XCTAssertEqual(result.text, "restored-transcript")
        XCTAssertEqual(plugin.restoreCount, 1)
    }

    func testTranscribeThrowsModelNotLoadedWhenRestoreStaysSilentPastBaseWindow() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        // Old behavior: the restore only becomes visible once the load actually
        // starts, after the base window has elapsed. The host cannot distinguish
        // this from a dead plugin and reports the engine as not loaded.
        let plugin = RestoreAfterUnloadMockPlugin(
            configured: false,
            restoreResult: .succeedAfter(.milliseconds(300)),
            publishesActivitySynchronously: false
        )
        let modelManager = installPlugin(plugin, appSupportDirectory: appSupportDirectory)
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 2,
            busyAttempts: 200,
            pollInterval: .milliseconds(50)
        )

        do {
            _ = try await modelManager.transcribe(
                audioSamples: [Float](repeating: 0, count: 1_600),
                language: nil,
                task: .transcribe
            )
            XCTFail("expected modelNotLoaded when the restore publishes no activity in time")
        } catch let error as TranscriptionEngineError {
            guard case .modelNotLoaded = error else {
                XCTFail("expected modelNotLoaded, got \(error)")
                return
            }
        }
    }

    func testTranscribeSurfacesRestoreErrorInsteadOfModelNotLoaded() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = RestoreAfterUnloadMockPlugin(
            configured: false,
            restoreResult: .fail("No previously loaded model to restore."),
            publishesActivitySynchronously: true
        )
        let modelManager = installPlugin(plugin, appSupportDirectory: appSupportDirectory)
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 20,
            busyAttempts: 200,
            pollInterval: .milliseconds(50)
        )

        do {
            _ = try await modelManager.transcribe(
                audioSamples: [Float](repeating: 0, count: 1_600),
                language: nil,
                task: .transcribe
            )
            XCTFail("expected modelLoadFailed when the restore reports an error")
        } catch let error as TranscriptionEngineError {
            guard case .modelLoadFailed(let message) = error else {
                XCTFail("expected modelLoadFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("No previously loaded model to restore."),
                "the underlying restore error must be surfaced, got: \(message)"
            )
        }
    }

    func testTranscribeWithoutUnloadDoesNotTriggerRestore() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        // Never-unload equivalent: the model was never released, so dictation
        // proceeds directly without a restore round-trip.
        let plugin = RestoreAfterUnloadMockPlugin(
            configured: true,
            restoreResult: .succeedAfter(.milliseconds(0)),
            publishesActivitySynchronously: true
        )
        let modelManager = installPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 1_600),
            language: nil,
            task: .transcribe
        )

        XCTAssertEqual(result.text, "restored-transcript")
        XCTAssertEqual(plugin.restoreCount, 0)
    }

    // MARK: - Helpers

    private func installPlugin(
        _ plugin: RestoreAfterUnloadMockPlugin,
        appSupportDirectory: URL
    ) -> ModelManagerService {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: RestoreAfterUnloadMockPlugin.pluginId,
                    name: RestoreAfterUnloadMockPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "RestoreAfterUnloadMockPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)
        return modelManager
    }
}

private final class RestoreAfterUnloadMockPlugin: NSObject, TranscriptionEnginePlugin, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.restore-after-unload"
    static let pluginName = "Mock Restore After Unload"

    enum RestoreResult: Sendable {
        case succeedAfter(Duration)
        case fail(String)
    }

    private let lock = NSLock()
    private var _configured: Bool
    private var _restoreInFlight = false
    private var _restoreError: String?
    private var _restoreCount = 0
    private let _restoreResult: RestoreResult
    private let _publishesActivitySynchronously: Bool

    init(
        configured: Bool,
        restoreResult: RestoreResult,
        publishesActivitySynchronously: Bool
    ) {
        _configured = configured
        _restoreResult = restoreResult
        _publishesActivitySynchronously = publishesActivitySynchronously
        super.init()
    }

    required override init() {
        _configured = true
        _restoreResult = .succeedAfter(.milliseconds(0))
        _publishesActivitySynchronously = true
        super.init()
    }

    var providerId: String { "mock-restore-after-unload" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { lock.withLock { _configured } }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
    var selectedModelId: String? { "tiny" }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { ["en"] }

    var restoreCount: Int { lock.withLock { _restoreCount } }

    func activate(host: HostServices) {}
    func deactivate() {}

    var currentSettingsActivity: PluginSettingsActivity? {
        lock.withLock {
            if let message = _restoreError {
                return PluginSettingsActivity(message: message, isError: true)
            }
            return _restoreInFlight ? PluginSettingsActivity(message: "Restoring model") : nil
        }
    }

    @objc func triggerRestoreModel() {
        let result = lock.withLock { () -> RestoreResult in
            _restoreCount += 1
            // Post-#840 plugins publish the restore activity synchronously so
            // the host extends its restore wait while the async load runs.
            if _publishesActivitySynchronously, !_configured {
                _restoreInFlight = true
            }
            return _restoreResult
        }
        Task { [weak self] in
            switch result {
            case .succeedAfter(let delay):
                try? await Task.sleep(for: delay)
                self?.lock.withLock {
                    // Pre-#840 behavior: the activity only appears once the load
                    // actually starts, which is after the host gave up.
                    $0._restoreInFlight = true
                }
                try? await Task.sleep(for: .milliseconds(50))
                self?.lock.withLock {
                    $0._configured = true
                    $0._restoreInFlight = false
                }
            case .fail(let message):
                try? await Task.sleep(for: .milliseconds(50))
                self?.lock.withLock {
                    $0._restoreError = message
                    $0._restoreInFlight = false
                }
            }
        }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "restored-transcript", detectedLanguage: language)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
    }
}
