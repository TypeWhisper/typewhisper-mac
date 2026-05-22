import XCTest
import AppKit
@testable import TypeWhisper

final class DictationViewModelIndicatorSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DictationViewModelIndicatorSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIndicatorTranscriptPreviewDefaultsToEnabled() {
        XCTAssertTrue(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testIndicatorTranscriptPreviewPersistsWhenDisabled() {
        DictationViewModel.persistIndicatorTranscriptPreviewEnabled(false, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool,
            false
        )
        XCTAssertFalse(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testMissingIndicatorTranscriptPreviewKeyFallsBackToTrue() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)

        XCTAssertTrue(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testIndicatorTranscriptPreviewFontSizeOffsetDefaultsToZero() {
        XCTAssertEqual(DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults), 0)
    }

    func testIndicatorTranscriptPreviewFontSizeOffsetPersistsClampedValue() {
        DictationViewModel.persistIndicatorTranscriptPreviewFontSizeOffset(99, defaults: defaults)

        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset) as? Int, 8)
        XCTAssertEqual(DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults), 8)
    }

    func testMissingIndicatorTranscriptPreviewFontSizeOffsetFallsBackToZero() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)

        XCTAssertEqual(DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults), 0)
    }

    func testInvalidIndicatorTranscriptPreviewFontSizeOffsetFallsBackToZero() {
        defaults.set("large", forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)

        XCTAssertEqual(DictationViewModel.loadIndicatorTranscriptPreviewFontSizeOffset(defaults: defaults), 0)
    }

    func testIndicatorTranscriptPreviewFontSizeDefaultsMatchCurrentStyles() {
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .notch, offset: 0), 12)
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .overlay, offset: 0), 13)
    }

    func testIndicatorStyleDefaultsToNotch() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorStyle)

        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .notch)
    }

    func testIndicatorStylePersistsMinimal() {
        DictationViewModel.persistIndicatorStyle(.minimal, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.indicatorStyle), IndicatorStyle.minimal.rawValue)
        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .minimal)
    }

    func testUnknownIndicatorStyleFallsBackToNotch() {
        defaults.set("mystery", forKey: UserDefaultsKeys.indicatorStyle)

        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .notch)
    }

    func testAggressiveShortSpeechTranscriptionDefaultsToEnabled() {
        XCTAssertTrue(DictationViewModel.loadTranscribeShortQuietClipsAggressively(defaults: defaults))
    }

    func testAggressiveShortSpeechTranscriptionPersistsWhenEnabled() {
        DictationViewModel.persistTranscribeShortQuietClipsAggressively(true, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool,
            true
        )
        XCTAssertTrue(DictationViewModel.loadTranscribeShortQuietClipsAggressively(defaults: defaults))
    }
}

final class IndicatorScreenResolverTests: XCTestCase {
    @MainActor
    func testActiveScreenPrefersFocusedElementBeforeWindowLookup() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var windowLookupCalled = false
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            frontmostApplicationProvider: { NSRunningApplication.current },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return .zero
            },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in
                windowLookupCalled = true
                return screen.frame
            }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertFalse(windowLookupCalled)
        XCTAssertFalse(mouseLookupCalled)
    }

    @MainActor
    func testActiveScreenUsesWindowFrameBeforeMouseFallback() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { NSRunningApplication.current },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return .zero
            },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in screen.frame }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertFalse(mouseLookupCalled)
    }

    @MainActor
    func testActiveScreenUsesFocusedWindowBeforeFrontmostApplicationFallback() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var frontmostWindowLookupCalled = false
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { screen.frame },
            frontmostApplicationProvider: { NSRunningApplication.current },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return .zero
            },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in
                frontmostWindowLookupCalled = true
                return .zero
            }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertFalse(frontmostWindowLookupCalled)
        XCTAssertFalse(mouseLookupCalled)
    }

    @MainActor
    func testActiveScreenFallsBackToMouseLocation() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { NSRunningApplication.current },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
            },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertTrue(mouseLookupCalled)
    }
}

final class IndicatorFullscreenSuppressionPolicyTests: XCTestCase {
    private let notchedScreenFrame = CGRect(x: 0, y: 0, width: 3024, height: 1964)

    func testSuppressesForeignFullscreenWindowThatOverlapsNotchStrip() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenWindow,
                frontmostBundleIdentifier: "com.apple.ScreenSharing",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testSuppressesForeignAXFullscreenWindowThatOverlapsNotchStrip() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenWindow,
                focusedWindowIsFullscreen: true,
                frontmostBundleIdentifier: "com.apple.ScreenSharing",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressForeignMaximizedWindowWhenAXReportsNotFullscreen() {
        let maximizedWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: maximizedWindow,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.google.Chrome",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressForeignMaximizedWindowWhenAXFullscreenIsUnavailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let maximizedWindowBelowMenuBar = CGRect(x: 7, y: 46, width: 1497, height: 929)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: maximizedWindowBelowMenuBar,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.microsoft.VSCode",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressOnNonNotchedScreen() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 0,
                windowFrame: fullscreenWindow,
                frontmostBundleIdentifier: "com.apple.ScreenSharing",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressNormalWindowBelowNotchStrip() {
        let maximizedWindowBelowMenuBar = CGRect(x: 0, y: 0, width: 3024, height: 1880)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: maximizedWindowBelowMenuBar,
                frontmostBundleIdentifier: "com.apple.TextEdit",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressTypeWhisperWindows() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenWindow,
                frontmostBundleIdentifier: "com.typewhisper.mac.dev",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testDoesNotSuppressNonNotchPlacementEvenOverForeignFullscreenWindow() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenWindow,
                frontmostBundleIdentifier: "com.apple.ScreenSharing",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea
            )
        )
    }

    func testNotchStripPlacementStillSuppressesAsBefore() {
        let fullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenWindow,
                frontmostBundleIdentifier: "com.apple.ScreenSharing",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .notchStrip
            )
        )
    }
}

final class DockIconVisibilityTests: XCTestCase {
    func testDockIconStaysHiddenWhenMenuBarIconIsVisibleAndNoWindowIsOpen() {
        XCTAssertFalse(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: true,
                dockIconBehavior: .keepVisible,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconStaysVisibleWhenMenuBarIconIsHiddenAndBehaviorKeepsItVisible() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .keepVisible,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconStaysHiddenWhenMenuBarIconIsHiddenAndBehaviorRequiresWindow() {
        XCTAssertFalse(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconAppearsWhileManagedWindowIsVisibleEvenWhenBehaviorRequiresWindow() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: true
            )
        )
    }

    func testDockIconAppearsForInteractiveForegroundContent() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: true,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: false,
                hasInteractiveForegroundContent: true
            )
        )
    }
}

final class MenuBarGroupingTests: XCTestCase {
    func testMenuBarSectionsUseExpectedOrderAndLocalizedKeys() {
        XCTAssertEqual(
            MenuBarMenuSection.allCases.map(\.titleLocalizationKey),
            ["General", "Recorder", "Transcription", "Updates"]
        )
    }

    func testMenuBarSectionsContainExpectedItems() {
        XCTAssertEqual(
            MenuBarMenuSection.general.items,
            [.settings, .history, .errorLog]
        )
        XCTAssertEqual(
            MenuBarMenuSection.recorder.items,
            [.toggleRecorder]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: true),
            [.transcribeFile, .recoverLastRecording, .recentTranscriptions, .copyLastTranscription, .readBackLastTranscription]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: false),
            [.transcribeFile, .recentTranscriptions, .copyLastTranscription, .readBackLastTranscription]
        )
        XCTAssertEqual(
            MenuBarMenuSection.updates.items,
            [.checkForUpdates]
        )
    }
}

final class MenuBarIconStateTests: XCTestCase {
    func testRecordingIndicatorIsActiveDuringDictationRecording() {
        XCTAssertTrue(
            MenuBarIconState.isRecordingActive(
                dictationState: .recording,
                recorderState: .idle
            )
        )
    }

    func testRecordingIndicatorIsActiveDuringRecorderRecording() {
        XCTAssertTrue(
            MenuBarIconState.isRecordingActive(
                dictationState: .idle,
                recorderState: .recording
            )
        )
    }

    func testRecordingIndicatorIsInactiveWhileRecorderFinalizes() {
        XCTAssertFalse(
            MenuBarIconState.isRecordingActive(
                dictationState: .idle,
                recorderState: .finalizing
            )
        )
    }

    func testRecordingIndicatorIsInactiveWithoutActiveRecording() {
        XCTAssertFalse(
            MenuBarIconState.isRecordingActive(
                dictationState: .processing,
                recorderState: .idle
            )
        )
    }
}

final class IndicatorPresentationStateTests: XCTestCase {
    func testRecorderRecordingShowsRecordingPresentationWhenDictationIsIdle() {
        let presentation = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .recording
        )

        XCTAssertEqual(presentation.source, .recorder)
        XCTAssertEqual(presentation.state, .recording)
        XCTAssertTrue(presentation.isActiveDuringActivity)
    }

    func testRecorderFinalizingDoesNotShowRecorderActivity() {
        let presentation = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .finalizing
        )

        XCTAssertEqual(presentation.source, .dictation)
        XCTAssertEqual(presentation.state, .idle)
        XCTAssertFalse(presentation.isActiveDuringActivity)
    }

    func testDictationActiveStatesWinOverRecorderRecording() {
        let activeDictationStates: [DictationViewModel.State] = [
            .recording,
            .processing,
            .inserting,
            .error("failed")
        ]

        for state in activeDictationStates {
            let presentation = IndicatorPresentationState.resolve(
                dictationState: state,
                recorderState: .recording
            )

            XCTAssertEqual(presentation.source, .dictation)
            XCTAssertEqual(presentation.state, state)
            XCTAssertTrue(presentation.isActiveDuringActivity)
        }
    }

    func testVisibilityPolicyPreservesAlwaysDuringActivityAndNever() {
        let recorderPresentation = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .recording
        )
        let idlePresentation = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .idle
        )

        XCTAssertTrue(IndicatorPresentationState.shouldShow(
            visibility: .always,
            presentation: idlePresentation
        ))
        XCTAssertTrue(IndicatorPresentationState.shouldShow(
            visibility: .duringActivity,
            presentation: recorderPresentation
        ))
        XCTAssertFalse(IndicatorPresentationState.shouldShow(
            visibility: .duringActivity,
            presentation: idlePresentation
        ))
        XCTAssertFalse(IndicatorPresentationState.shouldShow(
            visibility: .never,
            presentation: recorderPresentation
        ))
    }
}

final class MenuBarLogoMarkImageTests: XCTestCase {
    func testBarLayoutFitsWithinMenuBarSlotWithVisibleGaps() {
        let rects = MenuBarLogoMarkImage.barRects(in: CGRect(x: 0, y: 0, width: 18, height: 18))

        XCTAssertEqual(rects.count, 5)
        XCTAssertGreaterThanOrEqual(rects[0].minX, 0)
        XCTAssertLessThanOrEqual(rects[4].maxX, 18)
        XCTAssertGreaterThan(rects[2].height, rects[0].height)

        for index in 1..<rects.count {
            XCTAssertGreaterThanOrEqual(rects[index].minX - rects[index - 1].maxX, 1)
        }
    }

    func testIdleImageIsTemplateAndRecordingImageIsOriginalRedArtwork() {
        let idleImage = MenuBarLogoMarkImage.image(isRecordingActive: false)
        let recordingImage = MenuBarLogoMarkImage.image(isRecordingActive: true)

        XCTAssertEqual(idleImage.size, MenuBarLogoMarkImage.size)
        XCTAssertEqual(recordingImage.size, MenuBarLogoMarkImage.size)
        XCTAssertTrue(idleImage.isTemplate)
        XCTAssertFalse(recordingImage.isTemplate)
    }
}

final class RecorderMenuActionStateTests: XCTestCase {
    func testRecorderToggleIsEnabledWhenIdleAndMicIsEnabled() {
        XCTAssertTrue(
            AudioRecorderViewModel.canToggleRecording(
                state: .idle,
                micEnabled: true,
                systemAudioEnabled: false
            )
        )
    }

    func testRecorderToggleIsEnabledWhenIdleAndSystemAudioIsEnabled() {
        XCTAssertTrue(
            AudioRecorderViewModel.canToggleRecording(
                state: .idle,
                micEnabled: false,
                systemAudioEnabled: true
            )
        )
    }

    func testRecorderToggleIsEnabledWhileRecording() {
        XCTAssertTrue(
            AudioRecorderViewModel.canToggleRecording(
                state: .recording,
                micEnabled: false,
                systemAudioEnabled: false
            )
        )
    }

    func testRecorderToggleIsDisabledWhileFinalizing() {
        XCTAssertFalse(
            AudioRecorderViewModel.canToggleRecording(
                state: .finalizing,
                micEnabled: true,
                systemAudioEnabled: true
            )
        )
    }

    func testRecorderToggleIsDisabledWhenIdleWithoutEnabledSources() {
        XCTAssertFalse(
            AudioRecorderViewModel.canToggleRecording(
                state: .idle,
                micEnabled: false,
                systemAudioEnabled: false
            )
        )
    }
}

final class LanguageLocalizationTests: XCTestCase {
    private var originalPreferredAppLanguage: String?
    private var originalPluginManager: PluginManager?

    override func setUp() {
        super.setUp()
        originalPreferredAppLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
        originalPluginManager = PluginManager.shared
    }

    override func tearDown() {
        if let originalPreferredAppLanguage {
            UserDefaults.standard.set(originalPreferredAppLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
        }
        PluginManager.shared = originalPluginManager
        originalPluginManager = nil
        super.tearDown()
    }

    func testLocalizedAppLanguageOptionsFollowPreferredAppLanguage() {
        UserDefaults.standard.set("en", forKey: UserDefaultsKeys.preferredAppLanguage)

        let options = localizedAppLanguageOptions(for: ["de", "en"])

        XCTAssertEqual(options.map(\.code), ["de", "en"])
        XCTAssertEqual(options.map(\.name), ["German", "English"])
    }

    func testLanguageSearchTermsIncludeEnglishAliasForEnglish() {
        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)

        let searchTerms = localizedAppLanguageSearchTerms(for: "en")

        XCTAssertTrue(searchTerms.contains(where: { $0.localizedCaseInsensitiveContains("english") }))
        XCTAssertTrue(searchTerms.contains(where: { $0.localizedCaseInsensitiveContains("englisch") }))
    }

    func testLocalizedAppLanguageNameDisplaysDeepgramMultilingualCode() {
        UserDefaults.standard.set("en", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(localizedAppLanguageName(for: "multi"), "Multilingual")

        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(localizedAppLanguageName(for: "multi"), "Mehrsprachig")
    }

    func testLanguageSearchTermsIncludeDeepgramMultilingualAliases() {
        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)

        let searchTerms = localizedAppLanguageSearchTerms(for: "multi")

        XCTAssertTrue(searchTerms.contains(where: { $0.caseInsensitiveCompare("multi") == .orderedSame }))
        XCTAssertTrue(searchTerms.contains(where: { $0.caseInsensitiveCompare("Multilingual") == .orderedSame }))
        XCTAssertTrue(searchTerms.contains(where: { $0.caseInsensitiveCompare("Mehrsprachig") == .orderedSame }))
    }

    @MainActor
    func testSettingsLanguageOptionsDoNotGoEmptyBeforePluginsLoad() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "LanguageFallbackTests")
        defer { TestSupport.remove(appSupportDirectory) }
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let codes = Set(settingsViewModel.availableLanguages.map(\.code))

        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("de"))
        XCTAssertTrue(codes.contains("fr"))
    }
}
