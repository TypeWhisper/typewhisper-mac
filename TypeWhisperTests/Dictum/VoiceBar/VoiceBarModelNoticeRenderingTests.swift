import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class VoiceBarModelNoticeRenderingTests: XCTestCase {
    func testModelNoticeRendersDownloadingAndReturnsToIdleAfterNoticeClears() async throws {
        try await withDownloadingModel { dictation, plugin in
            let panel = VoiceBarPanel()
            panel.startObserving()
            defer { panel.orderOut(nil) }
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(55)) }
            XCTAssertFalse(panel.isVisible)
            _ = dictation.apiStartRecording()
            XCTAssertEqual(dictation.modelNotice, .downloading(progress: nil))
            // 隐藏期间刷新已停止，模型提示出现后语音条仍要被唤醒并显示。
            for _ in 0..<40 where !panel.isVisible { try await Task.sleep(for: .milliseconds(55)) }
            XCTAssertTrue(panel.isVisible)

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
            // 状态 13 的提示按 3 秒反馈时限保持可见。
            XCTAssertEqual(presentation.state, .downloading(nil))
            for _ in 0..<40 where presentation.isActive {
                try await Task.sleep(for: .milliseconds(100))
                presentation.refresh(.shared)
            }
            XCTAssertFalse(presentation.isActive)
        }
    }

    func testSecondDictationAttemptShowsTheModelNoticeAgain() async throws {
        try await withDownloadingModel { dictation, _ in
            let presentation = VoiceBarPresentation()
            _ = dictation.apiStartRecording()
            presentation.refresh(.shared)
            XCTAssertEqual(presentation.state, .downloading(nil))

            try await waitForNoticeToExpire(dictation, presentation)
            XCTAssertFalse(presentation.isActive)

            _ = dictation.apiStartRecording()
            presentation.refresh(.shared)
            XCTAssertEqual(presentation.state, .downloading(nil))
            XCTAssertTrue(presentation.isActive)
        }
    }

    func testDismissedModelNoticeShowsAgainOnTheNextDictationAttempt() async throws {
        try await withDownloadingModel { dictation, _ in
            let presentation = VoiceBarPresentation()
            _ = dictation.apiStartRecording()
            presentation.refresh(.shared)
            XCTAssertTrue(presentation.isActive)

            presentation.dismissFeedback()
            presentation.refresh(.shared)
            XCTAssertFalse(presentation.isActive)

            try await waitForNoticeToExpire(dictation, presentation)
            _ = dictation.apiStartRecording()
            presentation.refresh(.shared)
            XCTAssertEqual(presentation.state, .downloading(nil))
            XCTAssertTrue(presentation.isActive)
        }
    }

    func testModelNotDownloadedAndFailedUseDedicatedStates() async throws {
        let presentation = VoiceBarPresentation()
        presentation.setStateForTesting(.notDownloaded)
        XCTAssertEqual(presentation.state, .notDownloaded)
        presentation.setStateForTesting(.modelFailed("Download failed"))
        XCTAssertEqual(presentation.state, .modelFailed("Download failed"))
    }

    private func waitForNoticeToExpire(_ dictation: DictationViewModel, _ presentation: VoiceBarPresentation) async throws {
        for _ in 0..<80 where dictation.modelNotice != nil || presentation.isActive {
            try await Task.sleep(for: .milliseconds(100))
            presentation.refresh(.shared)
        }
        XCTAssertNil(dictation.modelNotice)
    }

    private func withDownloadingModel(_ body: (DictationViewModel, Qwen3Plugin) async throws -> Void) async throws {
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
        // 前一个测试可能让共享听写模型停在带错误的插入状态。
        services.dictationViewModel.state = .idle
        try await body(services.dictationViewModel, plugin)
        plugin.explicitModelLoadTask?.cancel()
        await plugin.explicitModelLoadTask?.value
        for _ in 0..<60 where services.dictationViewModel.modelNotice != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
