import XCTest
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

    func testAggressiveShortSpeechTranscriptionDefaultsToDisabled() {
        XCTAssertFalse(DictationViewModel.loadTranscribeShortQuietClipsAggressively(defaults: defaults))
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
            ["General", "Transcription", "Updates"]
        )
    }

    func testMenuBarSectionsContainExpectedItems() {
        XCTAssertEqual(
            MenuBarMenuSection.general.items,
            [.settings, .history, .errorLog]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items,
            [.transcribeFile, .recentTranscriptions, .copyLastTranscription, .readBackLastTranscription]
        )
        XCTAssertEqual(
            MenuBarMenuSection.updates.items,
            [.checkForUpdates]
        )
    }
}

final class LanguageLocalizationTests: XCTestCase {
    private var originalPreferredAppLanguage: String?

    override func setUp() {
        super.setUp()
        originalPreferredAppLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
    }

    override func tearDown() {
        if let originalPreferredAppLanguage {
            UserDefaults.standard.set(originalPreferredAppLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
        }
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
}
