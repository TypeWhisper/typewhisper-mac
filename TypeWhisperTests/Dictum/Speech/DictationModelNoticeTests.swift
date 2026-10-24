import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class DictationModelNoticeTests: XCTestCase {
    func testDownloadingPreventsRecordingAndClearsNoticeAfterThreeSeconds() async throws {
        let services = ServiceContainer.shared
        let savedManager = PluginManager.shared
        let selected = services.modelManagerService.selectedProviderId
        let root = try TestSupport.makeTemporaryDirectory()
        let plugin = Qwen3Plugin()
        let host = NoticeHost(directory: root)
        let session = NoticeDownloadSession()
        let savedWizardCompleted = UserDefaults.standard.object(forKey: UserDefaultsKeys.setupWizardCompleted)
        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        PluginHTTPClient.configureForTesting { _ in session }
        defer {
            UserDefaults.standard.set(savedWizardCompleted, forKey: UserDefaultsKeys.setupWizardCompleted)
            plugin.deactivate()
            PluginHTTPClient.resetTestingHooks()
            PluginManager.shared = savedManager
            if let selected { services.modelManagerService.selectProvider(selected) }
            else { services.modelManagerService.clearProviderSelection() }
            TestSupport.remove(root)
        }
        plugin.activate(host: host)
        let manager = PluginManager(appSupportDirectory: root)
        manager.loadedPlugins = [LoadedPlugin(manifest: PluginManifest(id: Qwen3Plugin.pluginId,
            name: Qwen3Plugin.pluginName, version: "1.0.0", principalClass: "Qwen3Plugin"),
            instance: plugin, bundle: .main, sourceURL: root, isEnabled: true)]
        PluginManager.shared = manager
        services.modelManagerService.clearProviderSelection()
        services.modelManagerService.restoreProviderSelection()
        XCTAssertEqual(services.modelManagerService.selectedProviderId, "qwen3")
        for _ in 0..<100 where plugin.currentSettingsActivity == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(plugin.currentSettingsActivity)
        let dictation = services.dictationViewModel
        let oldError = dictation.lastDictationError
        let start = ContinuousClock.now
        let sessionID = dictation.apiStartRecording()
        XCTAssertEqual(dictation.modelNotice, .downloading(progress: nil))
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(dictation.apiDictationSession(id: sessionID)?.status, .failed)
        XCTAssertEqual(
            dictation.apiDictationSession(id: sessionID)?.error,
            String(localized: "The speech model is downloading.", table: "DictumSpeech")
        )
        XCTAssertEqual(dictation.lastDictationError?.message, oldError?.message)
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotNil(dictation.modelNotice)
        for _ in 0..<30 where dictation.modelNotice != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(dictation.modelNotice)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(3))
        XCTAssertEqual(dictation.state, .idle)
        plugin.explicitModelLoadTask?.cancel()
        await plugin.explicitModelLoadTask?.value
    }

    func testMissingEngineStillFailsTheSessionWithoutModelNotice() {
        let services = ServiceContainer.shared
        let selected = services.modelManagerService.selectedProviderId
        defer {
            if let selected { services.modelManagerService.selectProvider(selected) }
            else { services.modelManagerService.clearProviderSelection() }
        }
        services.modelManagerService.clearProviderSelection()
        let dictation = services.dictationViewModel
        let id = dictation.apiStartRecording()
        XCTAssertNil(dictation.modelNotice)
        XCTAssertEqual(dictation.apiDictationSession(id: id)?.status, .failed)
        XCTAssertNotNil(dictation.apiDictationSession(id: id)?.error)
    }
}

final class NoticeDownloadSession: PluginHTTPClientSession, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        while true { try await Task.sleep(for: .seconds(1)) }
    }
    func finishTasksAndInvalidate() {}
}

final class NoticeHost: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    let pluginDataDirectory: URL
    let eventBus: EventBusProtocol = NoticeEventBus()
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let availableRuleNames: [String] = []
    let shouldRestoreLoadedModelsPassively = false
    private let lock = NSLock()
    private var defaults: [String: Any] = [:]
    init(directory: URL) { pluginDataDirectory = directory }
    func storeSecret(key: String, value: String) throws {}
    func loadSecret(key: String) -> String? { nil }
    func userDefault(forKey key: String) -> Any? { lock.withLock { defaults[key] } }
    func setUserDefault(_ value: Any?, forKey key: String) { lock.withLock { defaults[key] = value } }
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

private final class NoticeEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
    func unsubscribe(id: UUID) {}
}
