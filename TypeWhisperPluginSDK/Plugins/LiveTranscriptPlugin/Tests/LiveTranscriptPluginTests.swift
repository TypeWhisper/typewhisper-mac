import AppKit
import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LiveTranscriptPlugin

@MainActor
final class LiveTranscriptPluginTests: XCTestCase {
    private func displayedText(from viewModel: LiveTranscriptViewModel) -> String {
        viewModel.paragraphs.map(\.text).joined(separator: " ")
    }

    func testAutoOpenDefaultsToDisabledWhenUnset() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertNil(host.userDefault(forKey: "autoOpen"))
        XCTAssertEqual(host.streamingDisplayActiveValues, [])
        XCTAssertEqual(eventBus.subscriberCount, 1)
    }

    func testStoredAutoOpenTrueIsPreservedOnActivation() throws {
        let host = try PluginTestHostServices(defaults: ["autoOpen": true])
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testEnablingAutoOpenRegistersStreamingDisplayExactlyOnce() throws {
        let host = try PluginTestHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateAutoOpenPreference(true)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(host.userDefault(forKey: "autoOpen") as? Bool, true)
        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testStoredAppearancePreferencesAreLoadedOnActivation() throws {
        let host = try PluginTestHostServices(defaults: [
            "fontSize": 18.0,
            "windowWidth": 640.0,
            "windowHeight": 440.0,
            "backgroundOpacity": 0.55,
        ])
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let appearance = plugin.appearanceForTesting
        XCTAssertEqual(appearance.fontSize, 18.0)
        XCTAssertEqual(appearance.windowWidth, 640.0)
        XCTAssertEqual(appearance.windowHeight, 440.0)
        XCTAssertEqual(appearance.backgroundOpacity, 0.55)
    }

    func testAppearancePreferenceUpdatesPersistClampedValues() throws {
        let host = try PluginTestHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateFontSizePreference(40.0)
        plugin.updateWindowWidthPreference(1200.0)
        plugin.updateWindowHeightPreference(80.0)
        plugin.updateBackgroundOpacityPreference(0.05)

        let appearance = plugin.appearanceForTesting
        XCTAssertEqual(appearance.fontSize, 24.0)
        XCTAssertEqual(appearance.windowWidth, 900.0)
        XCTAssertEqual(appearance.windowHeight, 180.0)
        XCTAssertEqual(appearance.backgroundOpacity, 0.20)
        XCTAssertEqual(host.userDefault(forKey: "fontSize") as? Double, 24.0)
        XCTAssertEqual(host.userDefault(forKey: "windowWidth") as? Double, 900.0)
        XCTAssertEqual(host.userDefault(forKey: "windowHeight") as? Double, 180.0)
        XCTAssertEqual(host.userDefault(forKey: "backgroundOpacity") as? Double, 0.20)
    }

    func testAutoOpenedPanelRestoresSavedFrameInsteadOfConfiguredDefaultSize() async throws {
        let autosaveKey = LiveTranscriptPanelFrameStore.defaultsKey(for: "LiveTranscriptPanel")
        let previousAutosaveValue = UserDefaults.standard.object(forKey: autosaveKey)
        defer {
            NSApp.windows.compactMap { $0 as? LiveTranscriptPanel }.forEach { $0.close() }
            if let previousAutosaveValue {
                UserDefaults.standard.set(previousAutosaveValue, forKey: autosaveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: autosaveKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: autosaveKey)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let savedFrame = NSRect(
            x: visibleFrame.minX + 80,
            y: visibleFrame.minY + 80,
            width: 560,
            height: 360
        )
        UserDefaults.standard.set(LiveTranscriptPanelFrameStore.storedString(for: savedFrame), forKey: autosaveKey)

        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(defaults: [
            "autoOpen": true,
            "windowWidth": 420.0,
            "windowHeight": 320.0,
        ], eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await eventBus.emit(.recordingStarted(RecordingStartedPayload(appName: "Notes")))

        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? LiveTranscriptPanel }.last)
        XCTAssertEqual(panel.frame.width, savedFrame.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, savedFrame.height, accuracy: 1)
        XCTAssertEqual(panel.frame.minX, savedFrame.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, savedFrame.minY, accuracy: 1)
    }

    func testPanelFrameStoreAcceptsSavedFrameOnSecondaryDisplay() throws {
        let mainDisplay = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let wideSecondaryDisplay = NSRect(x: 1728, y: -220, width: 3440, height: 1440)
        let savedFrame = NSRect(x: 2200, y: 140, width: 820, height: 480)
        let storedFrame = LiveTranscriptPanelFrameStore.storedString(for: savedFrame)

        let restoredFrame = try XCTUnwrap(LiveTranscriptPanelFrameStore.restorableFrame(
            from: storedFrame,
            screenVisibleFrames: [mainDisplay, wideSecondaryDisplay],
            minimumSize: NSSize(width: 250, height: 150)
        ))

        XCTAssertEqual(restoredFrame.minX, savedFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.minY, savedFrame.minY, accuracy: 1)
        XCTAssertEqual(restoredFrame.width, savedFrame.width, accuracy: 1)
        XCTAssertEqual(restoredFrame.height, savedFrame.height, accuracy: 1)
    }

    func testPanelPersistsFrameWhenMoved() throws {
        let autosaveName = "LiveTranscriptPanelImmediateMoveTest"
        let autosaveKey = LiveTranscriptPanelFrameStore.defaultsKey(for: autosaveName)
        let previousAutosaveValue = UserDefaults.standard.object(forKey: autosaveKey)
        defer {
            NSApp.windows.compactMap { $0 as? LiveTranscriptPanel }.forEach { $0.close() }
            if let previousAutosaveValue {
                UserDefaults.standard.set(previousAutosaveValue, forKey: autosaveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: autosaveKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: autosaveKey)
        let panel = LiveTranscriptPanel(
            viewModel: LiveTranscriptViewModel(),
            windowSize: NSSize(width: 420, height: 320),
            frameAutosaveName: autosaveName
        )
        let movedFrame = NSRect(x: 2400, y: 180, width: 860, height: 500)

        panel.setFrame(movedFrame, display: false)
        panel.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

        let storedFrame = try XCTUnwrap(UserDefaults.standard.string(forKey: autosaveKey))
        let restoredFrame = try XCTUnwrap(LiveTranscriptPanelFrameStore.restorableFrame(
            from: storedFrame,
            screenVisibleFrames: [NSRect(x: 1728, y: -220, width: 3440, height: 1440)],
            minimumSize: NSSize(width: 250, height: 150)
        ))

        XCTAssertEqual(restoredFrame.minX, movedFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.minY, movedFrame.minY, accuracy: 1)
        XCTAssertEqual(restoredFrame.width, movedFrame.width, accuracy: 1)
        XCTAssertEqual(restoredFrame.height, movedFrame.height, accuracy: 1)
    }

    func testManualPanelResizePersistsWindowSizePreferences() async throws {
        let autosaveKey = LiveTranscriptPanelFrameStore.defaultsKey(for: "LiveTranscriptPanel")
        let previousAutosaveValue = UserDefaults.standard.object(forKey: autosaveKey)
        defer {
            NSApp.windows.compactMap { $0 as? LiveTranscriptPanel }.forEach { $0.close() }
            if let previousAutosaveValue {
                UserDefaults.standard.set(previousAutosaveValue, forKey: autosaveKey)
            } else {
                UserDefaults.standard.removeObject(forKey: autosaveKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: autosaveKey)
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(defaults: [
            "autoOpen": true,
            "windowWidth": 420.0,
            "windowHeight": 320.0,
        ], eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await eventBus.emit(.recordingStarted(RecordingStartedPayload(appName: "Notes")))

        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? LiveTranscriptPanel }.last)
        panel.setContentSize(NSSize(width: 760, height: 460))
        panel.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))

        let storedWidth = try XCTUnwrap(host.userDefault(forKey: "windowWidth") as? Double)
        let storedHeight = try XCTUnwrap(host.userDefault(forKey: "windowHeight") as? Double)
        let appearance = plugin.appearanceForTesting
        XCTAssertEqual(storedWidth, 760.0, accuracy: 1)
        XCTAssertEqual(storedHeight, 460.0, accuracy: 1)
        XCTAssertEqual(appearance.windowWidth, 760.0, accuracy: 1)
        XCTAssertEqual(appearance.windowHeight, 460.0, accuracy: 1)
    }

    func testDeactivationUnsubscribesAndClearsStreamingDisplay() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(eventBus.subscriberCount, 1)

        plugin.deactivate()

        XCTAssertEqual(host.streamingDisplayActiveValues, [true, false])
        XCTAssertEqual(eventBus.subscriberCount, 0)
    }

    func testCompletionTextWinsOverLateFinalPreviewUpdate() async throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus, activeAppName: "Notes")
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateAutoOpenPreference(true)
        await eventBus.emit(.recordingStarted(RecordingStartedPayload(appName: "Notes")))
        await eventBus.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
            text: "Jetzt funktioniert es perfekt. funktioniert perfekt. Viel zu viel Preview.",
            elapsedSeconds: 2
        )))
        await eventBus.emit(.transcriptionCompleted(TranscriptionCompletedPayload(
            rawText: "raw",
            finalText: "Jetzt funktioniert es perfekt.",
            engineUsed: "parakeet",
            durationSeconds: 3,
            appName: "Notes",
            ruleName: nil
        )))
        await eventBus.emit(.partialTranscriptionUpdate(PartialTranscriptionPayload(
            text: "Jetzt funktioniert es perfekt. funktioniert perfekt. Viel zu viel Preview.",
            isFinal: true,
            elapsedSeconds: 3
        )))

        XCTAssertEqual(plugin.displayedTextForTesting, "Jetzt funktioniert es perfekt.")
    }

    func testViewModelDisplaysLatestCumulativeTranscriptSnapshot() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("First sentence. Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }

    func testViewModelShowsLatestDisjointProviderSnapshotWithoutAppending() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "Second sentence.")
    }

    func testViewModelShowsLatestOverlappingProviderSnapshotWithoutMerging() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("Second sentence. Third sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "Second sentence. Third sentence.")
    }

    func testViewModelShowsNoisyProviderSnapshotVerbatim() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText(
            "Das hier ist das klassische DJI-Setup. Also das sieht aus wie beim Mini 1, einfach dass die Dinger 2 sind. Das ueberrascht mich ein bisschen.",
            isFinal: false
        )
        viewModel.updateText(
            "Mini 1, einlech dass sie Dinge 2 ist. Aber jetzt muessen wir nichts anderes angucken.",
            isFinal: false
        )

        XCTAssertEqual(
            displayedText(from: viewModel),
            "Mini 1, einlech dass sie Dinge 2 ist. Aber jetzt muessen wir nichts anderes angucken."
        )
    }

    func testViewModelShowsLatestShorterProviderSnapshot() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("First sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence.")
    }

    func testViewModelDoesNotInterpretSpokenParagraphCommands() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("Erster Teil. Neuer Absatz. Zweiter Teil.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "Erster Teil. Neuer Absatz. Zweiter Teil.")
    }

    func testFinalUpdateReplacesPreviewText() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("Vorheriger Live-Text. Ich bin an Koin.", isFinal: false)
        viewModel.updateText("Ich bin an Koeln.", isFinal: true)

        XCTAssertEqual(displayedText(from: viewModel), "Ich bin an Koeln.")
    }

    func testFinalEmptyUpdateClearsPreviewText() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("Incorrect live preview.", isFinal: false)
        viewModel.updateText("   ", isFinal: true)

        XCTAssertEqual(displayedText(from: viewModel), "")
        XCTAssertTrue(viewModel.paragraphs.isEmpty)
    }

    func testViewModelAllowsProviderCorrectionsByReplacingSnapshot() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText(
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koin. Und jetzt sind sie wieder in einer Stadt. Am proben Fluss gelandes.",
            isFinal: false
        )
        viewModel.updateText(
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koeln. Und jetzt sind sie wieder. Wieder in einer Stadt am grossen Fluss gelandet. Genau.",
            isFinal: false
        )

        XCTAssertEqual(
            displayedText(from: viewModel),
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koeln. Und jetzt sind sie wieder. Wieder in einer Stadt am grossen Fluss gelandet. Genau."
        )
    }

    func testViewModelIgnoresDuplicateSnapshots() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("First sentence. Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
        XCTAssertEqual(viewModel.paragraphs.count, 1)
    }
}
