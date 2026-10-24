import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class VoiceBarModelNoticeRenderingTests: XCTestCase {
    func testModelNoticeRendersDownloadingAndReturnsToIdleAfterNoticeClears() async throws {
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
        _ = dictation.apiStartRecording()
        XCTAssertEqual(dictation.modelNotice, .downloading(progress: nil))

        let presentation = VoiceBarPresentation()
        presentation.refresh(.shared)
        XCTAssertEqual(presentation.state, .downloading(nil))
        XCTAssertTrue(presentation.isActive)

        plugin.explicitModelLoadTask?.cancel()
        await plugin.explicitModelLoadTask?.value
        for _ in 0..<60 where dictation.modelNotice != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(dictation.modelNotice)
        presentation.refresh(.shared)
        // State 13 keeps the notice visible for its 3-second feedback lifetime.
        XCTAssertEqual(presentation.state, .downloading(nil))
        for _ in 0..<40 where presentation.isActive {
            try await Task.sleep(for: .milliseconds(100))
            presentation.refresh(.shared)
        }
        XCTAssertFalse(presentation.isActive)
    }
}
