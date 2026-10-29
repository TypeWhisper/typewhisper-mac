import XCTest
import AppKit
import CoreGraphics
import SwiftUI
@testable import TypeWhisper

@MainActor
private func quartzDisplayBounds(for screen: NSScreen) -> CGRect? {
    guard let screenNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
    ] as? NSNumber else {
        return nil
    }

    return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
}

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

    func testLiveFieldTranscriptDefaultsToDisabled() {
        XCTAssertFalse(DictationViewModel.loadLiveFieldTranscriptEnabled(defaults: defaults))
    }

    func testLiveFieldTranscriptPersistsWhenEnabled() {
        DictationViewModel.persistLiveFieldTranscriptEnabled(true, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.liveFieldTranscriptEnabled) as? Bool,
            true
        )
        XCTAssertTrue(DictationViewModel.loadLiveFieldTranscriptEnabled(defaults: defaults))
    }

    func testMissingIndicatorTranscriptPreviewKeyFallsBackToTrue() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)

        XCTAssertTrue(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testIndicatorDefaultsToVisibleInScreenCaptures() {
        XCTAssertTrue(DictationViewModel.loadIndicatorVisibleInScreenCaptures(defaults: defaults))
    }

    func testIndicatorScreenCaptureVisibilityPersistsWhenDisabled() {
        DictationViewModel.persistIndicatorVisibleInScreenCaptures(false, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.indicatorVisibleInScreenCaptures) as? Bool,
            false
        )
        XCTAssertFalse(DictationViewModel.loadIndicatorVisibleInScreenCaptures(defaults: defaults))
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

    func testIndicatorThemeDefaultsToClassic() {
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.indicatorTheme))
        XCTAssertEqual(DictationViewModel.loadIndicatorTheme(defaults: defaults), .classic)
    }

    func testIndicatorThemePersistsGlass() {
        DictationViewModel.persistIndicatorTheme(.glass, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.indicatorTheme), IndicatorTheme.glass.rawValue)
        XCTAssertEqual(DictationViewModel.loadIndicatorTheme(defaults: defaults), .glass)
    }

    func testUnknownIndicatorThemeFallsBackToClassic() {
        defaults.set("neon", forKey: UserDefaultsKeys.indicatorTheme)

        XCTAssertEqual(DictationViewModel.loadIndicatorTheme(defaults: defaults), .classic)
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

    func testCancellationBehaviorDefaultsToDoubleEscape() {
        XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: defaults), .doubleEscape)
    }

    func testCancellationBehaviorMigratesLegacyPreference() {
        for enabled in [true, false] {
            defaults.set(enabled, forKey: UserDefaultsKeys.requireSecondEscapeToCancelRecording)
            XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: defaults), enabled ? .doubleEscape : .singleEscape)
        }
    }

    func testCancellationBehaviorPersistsAllModesAndOverridesLegacyPreference() {
        defaults.set(false, forKey: UserDefaultsKeys.requireSecondEscapeToCancelRecording)
        for behavior in CancellationBehavior.allCases {
            DictationViewModel.persistCancellationBehavior(behavior, defaults: defaults)
            XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: defaults), behavior)
        }
    }

    func testInvalidCancellationBehaviorFallsBackToLegacyOrDefault() {
        defaults.set("unknown", forKey: UserDefaultsKeys.cancellationBehavior)
        XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: defaults), .doubleEscape)
        defaults.set(false, forKey: UserDefaultsKeys.requireSecondEscapeToCancelRecording)
        XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: defaults), .singleEscape)
    }

    func testMicrophoneBoostDefaultsToDisabled() {
        XCTAssertFalse(DictationViewModel.loadMicrophoneBoostEnabled(defaults: defaults))
    }

    func testMicrophoneBoostPersistsWhenEnabled() {
        DictationViewModel.persistMicrophoneBoostEnabled(true, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.microphoneBoostEnabled) as? Bool,
            true
        )
        XCTAssertTrue(DictationViewModel.loadMicrophoneBoostEnabled(defaults: defaults))
    }

    func testMicrophoneBoostPersistsWhenDisabled() {
        DictationViewModel.persistMicrophoneBoostEnabled(false, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.microphoneBoostEnabled) as? Bool,
            false
        )
        XCTAssertFalse(DictationViewModel.loadMicrophoneBoostEnabled(defaults: defaults))
    }
}

final class IndicatorScreenResolverTests: XCTestCase {
    @MainActor
    func testActiveScreenPrefersFocusedElementBeforeWindowLookup() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let quartzBounds = try XCTUnwrap(quartzDisplayBounds(for: screen))
        var windowLookupCalled = false
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { CGPoint(x: quartzBounds.midX, y: quartzBounds.midY) },
            frontmostApplicationProvider: { NSRunningApplication.current },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return .zero
            },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in
                windowLookupCalled = true
                return quartzBounds
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
        let quartzBounds = try XCTUnwrap(quartzDisplayBounds(for: screen))
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
            windowFrameProvider: { _ in quartzBounds }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertFalse(mouseLookupCalled)
    }

    @MainActor
    func testActiveScreenUsesFocusedWindowBeforeFrontmostApplicationFallback() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let quartzBounds = try XCTUnwrap(quartzDisplayBounds(for: screen))
        var frontmostWindowLookupCalled = false
        var mouseLookupCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { quartzBounds },
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

    @MainActor
    func testActiveScreenFallsBackToMainScreenWhenNoSourceResolves() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var mouseLookupCalled = false
        var mainScreenProviderCalled = false

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: {
                mouseLookupCalled = true
                return CGPoint(x: screen.frame.maxX + 10_000, y: screen.frame.maxY + 10_000)
            },
            screensProvider: { [screen] },
            mainScreenProvider: {
                mainScreenProviderCalled = true
                return screen
            },
            windowFrameProvider: { _ in nil }
        )

        let resolvedScreen = resolver.resolveScreen(for: .activeScreen)

        XCTAssertTrue(resolvedScreen === screen)
        XCTAssertTrue(mouseLookupCalled)
        XCTAssertTrue(mainScreenProviderCalled)
    }
}

final class IndicatorScreenGeometryTests: XCTestCase {
    func testQuartzPointUsesQuartzBoundsForVerticallyStackedDisplays() {
        let displays = verticallyStackedDisplays()
        let point = CGPoint(x: 960, y: -540)

        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                containing: point,
                among: [displays.primary, displays.top, displays.bottom],
                in: .quartz
            ),
            displays.top.identifier
        )
        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                containing: point,
                among: [displays.primary, displays.top, displays.bottom],
                in: .appKit
            ),
            displays.bottom.identifier
        )
    }

    func testQuartzWindowFrameUsesLargestIntersection() {
        let displays = verticallyStackedDisplays()
        let frame = CGRect(x: 100, y: -1_000, width: 1_000, height: 1_100)

        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                intersecting: frame,
                among: [displays.primary, displays.top, displays.bottom],
                in: .quartz
            ),
            displays.top.identifier
        )
        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                intersecting: frame,
                among: [displays.primary, displays.top, displays.bottom],
                in: .appKit
            ),
            displays.bottom.identifier
        )
    }

    func testQuartzWindowFrameFallsBackToItsCenter() {
        let displays = verticallyStackedDisplays()
        let frame = CGRect(x: 960, y: -540, width: 0, height: 0)

        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                intersecting: frame,
                among: [displays.primary, displays.top, displays.bottom],
                in: .quartz
            ),
            displays.top.identifier
        )
    }

    func testAppKitMousePointUsesAppKitFrames() {
        let displays = verticallyStackedDisplays()
        let point = CGPoint(x: 960, y: -540)

        XCTAssertEqual(
            IndicatorScreenGeometry.displayIdentifier(
                containing: point,
                among: [displays.primary, displays.top, displays.bottom],
                in: .appKit
            ),
            displays.bottom.identifier
        )
    }

    func testQuartzLookupSkipsDisplaysWithoutQuartzBounds() {
        let displays = verticallyStackedDisplays()
        let unavailableTop = IndicatorScreenGeometry(
            identifier: displays.top.identifier,
            appKitFrame: displays.top.appKitFrame,
            quartzDisplayBounds: nil
        )

        XCTAssertNil(
            IndicatorScreenGeometry.displayIdentifier(
                containing: CGPoint(x: 960, y: 1_440),
                among: [unavailableTop],
                in: .quartz
            )
        )
    }

    private func verticallyStackedDisplays() -> (
        primary: IndicatorScreenGeometry,
        top: IndicatorScreenGeometry,
        bottom: IndicatorScreenGeometry
    ) {
        let primary = IndicatorScreenGeometry(
            identifier: 1,
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            quartzDisplayBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let top = IndicatorScreenGeometry(
            identifier: 2,
            appKitFrame: CGRect(x: 0, y: 900, width: 1_920, height: 1_080),
            quartzDisplayBounds: CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080)
        )
        let bottom = IndicatorScreenGeometry(
            identifier: 3,
            appKitFrame: CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080),
            quartzDisplayBounds: CGRect(x: 0, y: 900, width: 1_920, height: 1_080)
        )
        return (primary, top, bottom)
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

    func testSuppressesForeignAXFullscreenContentWindowBelowNotchStripForNotchPlacement() {
        let fullscreenContentWindowBelowNotchStrip = CGRect(x: 0, y: 0, width: 3024, height: 1890)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenContentWindowBelowNotchStrip,
                focusedWindowIsFullscreen: true,
                frontmostBundleIdentifier: "com.google.Chrome",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .notchStrip
            )
        )
    }

    func testDoesNotSuppressForeignAXFullscreenContentWindowBelowNotchStripForNonNotchPlacement() {
        let fullscreenContentWindowBelowNotchStrip = CGRect(x: 0, y: 0, width: 3024, height: 1890)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: fullscreenContentWindowBelowNotchStrip,
                focusedWindowIsFullscreen: true,
                frontmostBundleIdentifier: "com.google.Chrome",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea
            )
        )
    }

    func testSuppressesForeignFullscreenContentWindowBelowNotchStripWhenAXFullscreenIsUnavailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fullscreenContentWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: fullscreenContentWindowBelowNotch,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.brave.Browser",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .notchStrip
            )
        )
    }

    func testDoesNotSuppressForeignFullscreenContentWindowBelowNotchStripForBottomPlacementWhenAXFullscreenIsUnavailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fullscreenContentWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: fullscreenContentWindowBelowNotch,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.brave.Browser",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea
            )
        )
    }

    func testSuppressesWhenFocusedWindowIsTransientButApplicationHasFullscreenContentBelowNotch() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let transientToolbarWindow = CGRect(x: 0, y: 0, width: 1512, height: 41)
        let fullscreenContentWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: transientToolbarWindow,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.brave.Browser",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .notchStrip,
                applicationWindowFrames: [fullscreenContentWindowBelowNotch]
            )
        )
    }

    func testDoesNotSuppressBottomPlacementWhenFocusedWindowIsTransientButApplicationHasFullscreenContentBelowNotch() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let transientToolbarWindow = CGRect(x: 0, y: 0, width: 1512, height: 41)
        let fullscreenContentWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: transientToolbarWindow,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.brave.Browser",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                applicationWindowFrames: [fullscreenContentWindowBelowNotch]
            )
        )
    }

    func testDoesNotSuppressMaximizedMainWindowWhenApplicationWindowScanSeesSameFrameAndAXReportsNotFullscreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let maximizedWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: maximizedWindowBelowNotch,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.brave.Browser",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .notchStrip,
                applicationWindowFrames: [maximizedWindowBelowNotch]
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

    func testDoesNotSuppressSafariMaximizedWindowWhenAXReportsNotFullscreen() {
        let safariMaximizedWindow = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                safeAreaTopInset: 32,
                windowFrame: safariMaximizedWindow,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.apple.Safari",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testSuppressesSafariTechnologyPreviewFullscreenLikeWindow() {
        let safariFullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: safariFullscreenWindow,
                focusedWindowIsFullscreen: true,
                frontmostBundleIdentifier: "com.apple.SafariTechnologyPreview",
                appBundleIdentifier: "com.typewhisper.mac.dev"
            )
        )
    }

    func testSuppressesSafariFullscreenLikeWindowForNonNotchPlacement() {
        let safariFullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: safariFullscreenWindow,
                focusedWindowIsFullscreen: true,
                frontmostBundleIdentifier: "com.apple.Safari",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea
            )
        )
    }

    func testSuppressesSafariWindowScanWhenFrontmostLookupMissesSafari() {
        let safariFullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: nil,
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariFullscreenWindow, isFullscreen: true)
                ]
            )
        )
    }

    func testSuppressesSafariWindowScanWhenTypeWhisperIsFrontmost() {
        let safariFullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.typewhisper.mac.dev",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariFullscreenWindow, isFullscreen: true)
                ]
            )
        )
    }

    func testSuppressesSafariContentWindowThatStartsBelowNotchStrip() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let safariContentWindowBelowNotch = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.typewhisper.mac.dev",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariContentWindowBelowNotch, isFullscreen: true)
                ]
            )
        )
    }

    func testDoesNotSuppressMaximizedSafariWindowScanWhenAXReportsNotFullscreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let safariMaximizedWindow = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.typewhisper.mac.dev",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariMaximizedWindow, isFullscreen: false)
                ]
            )
        )
    }

    func testKeepsSafariGeometryFallbackWhenAXFullscreenIsUnavailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let safariFullscreenWindow = CGRect(x: 0, y: 33, width: 1512, height: 949)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: screenFrame,
                safeAreaTopInset: 32,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: "com.typewhisper.mac.dev",
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariFullscreenWindow, isFullscreen: nil)
                ]
            )
        )
    }

    func testDoesNotSuppressSafariWindowScanForNormalWindowBelowNotchStrip() {
        let safariWindowBelowMenuBar = CGRect(x: 7, y: 46, width: 3008, height: 1870)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: nil,
                focusedWindowIsFullscreen: nil,
                frontmostBundleIdentifier: nil,
                appBundleIdentifier: "com.typewhisper.mac.dev",
                placement: .nonNotchArea,
                safariWindows: [
                    SafariWindowSnapshot(frame: safariWindowBelowMenuBar, isFullscreen: nil)
                ]
            )
        )
    }

    func testDoesNotSuppressSafariWindowBelowNotchStripWhenAXReportsNotFullscreen() {
        let safariWindowBelowMenuBar = CGRect(x: 7, y: 46, width: 3008, height: 1870)

        XCTAssertFalse(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: safariWindowBelowMenuBar,
                focusedWindowIsFullscreen: false,
                frontmostBundleIdentifier: "com.apple.Safari",
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

final class ManagedAppReopenSuppressionTests: XCTestCase {
    func testBackgroundInteractionSuppressesExactlyOneImmediateReopen() {
        let suppression = ManagedAppReopenSuppression(duration: 1.5)
        let now = Date(timeIntervalSince1970: 1_000)

        suppression.markBackgroundInteraction(at: now)

        XCTAssertTrue(suppression.consumeIfActive(at: now.addingTimeInterval(1)))
        XCTAssertFalse(suppression.consumeIfActive(at: now.addingTimeInterval(1)))
    }

    func testBackgroundInteractionSuppressionExpires() {
        let suppression = ManagedAppReopenSuppression(duration: 1.5)
        let now = Date(timeIntervalSince1970: 1_000)

        suppression.markBackgroundInteraction(at: now)

        XCTAssertFalse(suppression.consumeIfActive(at: now.addingTimeInterval(2)))
    }
}

@MainActor
final class ManagedAppWindowRestorationTests: XCTestCase {
    func testManagedWindowIsMarkedNonRestorable() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isRestorable = true

        ManagedAppWindowRestoration.disable(for: window)

        XCTAssertFalse(window.isRestorable)
    }
}

final class MenuBarGroupingTests: XCTestCase {
    @MainActor
    func testMenuBarActionDispatcherDefersUntilTheCurrentActionReturns() async {
        let probe = MenuBarActionInvocationProbe()

        await withCheckedContinuation { continuation in
            MenuBarActionDispatcher.performAfterMenuDismissal {
                probe.invocationCount += 1
                continuation.resume()
            }

            XCTAssertEqual(probe.invocationCount, 0)
        }

        XCTAssertEqual(probe.invocationCount, 1)
    }

    func testMenuBarSectionsUseExpectedOrderAndLocalizedKeys() {
        XCTAssertEqual(
            MenuBarMenuSection.allCases.map(\.titleLocalizationKey),
            ["General", "Transcription"]
        )
    }

    @MainActor
    func testDictationShortcutsListEveryConfiguredSlotWithItsMode() {
        let shortcuts = MenuBarStatusFormatting.dictationShortcuts { slot in
            switch slot {
            case .hybrid: ["Fn", "Fn F13"]
            case .toggle: ["⌥⌘A"]
            default: []
            }
        }

        XCTAssertEqual(
            shortcuts.map(\.title),
            ["Fn (\(String(localized: "Hybrid")))", "Fn F13 (\(String(localized: "Hybrid")))", "⌥⌘A (\(String(localized: "Toggle")))"]
        )
        XCTAssertTrue(MenuBarStatusFormatting.dictationShortcuts { _ in [] }.isEmpty)
    }

    func testErrorStatusTextKeepsShortMessagesAndCutsLongOnes() {
        XCTAssertEqual(
            MenuBarStatusFormatting.errorStatusText("  Microphone permission required. \n"),
            "Microphone permission required."
        )

        let long = String(repeating: "word ", count: 40)
        let cut = MenuBarStatusFormatting.errorStatusText(long, limit: 20)
        XCTAssertEqual(cut, "word word word word…")

        XCTAssertEqual(
            MenuBarStatusFormatting.errorStatusText(
                "No transcription engine selected. Choose one under Settings > Dictation, or install one under Discover plugins."
            ),
            "No transcription engine selected."
        )
        // Japanese sentences end in "。", which counts as a sentence end as well.
        XCTAssertEqual(
            MenuBarStatusFormatting.errorStatusText(
                "文字起こしエンジンが選択されていません。設定 > ディクテーションで選択するか、プラグインを見つけるからインストールしてください。"
            ),
            "文字起こしエンジンが選択されていません。"
        )
    }

    func testMenuBarSectionsContainExpectedItems() {
        XCTAssertEqual(
            MenuBarMenuSection.general.items,
            [.settings, .history, .errorLog]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: true),
            [.toggleDictationHotkeysPause, .transcribeFile, .recoverLastRecording, .lastTranscription,
             .correctLastDictation]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: false),
            [.toggleDictationHotkeysPause, .transcribeFile, .lastTranscription, .correctLastDictation]
        )
    }
}

@MainActor
private final class MenuBarActionInvocationProbe {
    var invocationCount = 0
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
    private func makeRecordingPresentation(
        isInputReady: Bool,
        isModelLoading: Bool = false
    ) -> IndicatorPresentationData {
        IndicatorPresentationData(
            source: .dictation,
            state: .recording,
            recordingDuration: 0,
            audioLevel: 0,
            partialText: "",
            activeRuleName: nil,
            activeAppIcon: nil,
            isRecordingInputReady: isInputReady,
            isModelLoading: isModelLoading,
            warningMessage: nil,
            processingPhase: nil,
            actionFeedbackMessage: nil,
            actionFeedbackIcon: nil,
            actionFeedbackIsError: false,
            actionFeedbackActionTitle: nil,
            actionFeedbackRemainingFraction: nil,
            actionFeedbackIsPaused: false,
            externalStreamingDisplayCount: 0
        )
    }

    private func makeFeedbackPresentation(
        remainingFraction: Double,
        isPaused: Bool
    ) -> IndicatorPresentationData {
        IndicatorPresentationData(
            source: .dictation,
            state: .inserting,
            recordingDuration: 0,
            audioLevel: 0,
            partialText: "",
            activeRuleName: nil,
            activeAppIcon: nil,
            isRecordingInputReady: false,
            isModelLoading: false,
            warningMessage: nil,
            processingPhase: nil,
            actionFeedbackMessage: "Saved",
            actionFeedbackIcon: "checkmark.circle.fill",
            actionFeedbackIsError: false,
            actionFeedbackActionTitle: "Undo",
            actionFeedbackRemainingFraction: remainingFraction,
            actionFeedbackIsPaused: isPaused,
            externalStreamingDisplayCount: 0
        )
    }

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

    func testErrorFeedbackStillShowsWhenIndicatorIsSetToNever() {
        let errorFeedback = IndicatorPresentationState.resolve(
            dictationState: .inserting,
            recorderState: .idle,
            isErrorFeedback: true
        )
        let successFeedback = IndicatorPresentationState.resolve(
            dictationState: .inserting,
            recorderState: .idle,
            isErrorFeedback: false
        )
        let recordingWithStaleFlag = IndicatorPresentationState.resolve(
            dictationState: .recording,
            recorderState: .idle,
            isErrorFeedback: true
        )

        XCTAssertTrue(errorFeedback.isErrorFeedback)
        XCTAssertTrue(IndicatorPresentationState.shouldShow(visibility: .never, presentation: errorFeedback))
        XCTAssertFalse(IndicatorPresentationState.shouldShow(visibility: .never, presentation: successFeedback))
        XCTAssertFalse(recordingWithStaleFlag.isErrorFeedback)
        XCTAssertFalse(IndicatorPresentationState.shouldShow(visibility: .never, presentation: recordingWithStaleFlag))
    }

    func testPreviewFillsInOnlyWhileIdleAndIgnoresVisibility() {
        let idle = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .idle,
            previewActive: true
        )
        XCTAssertEqual(idle.source, .preview)
        XCTAssertEqual(idle.state, .recording)
        XCTAssertTrue(IndicatorPresentationState.shouldShow(visibility: .never, presentation: idle))
        XCTAssertTrue(IndicatorPresentationState.shouldShow(visibility: .duringActivity, presentation: idle))

        let recording = IndicatorPresentationState.resolve(
            dictationState: .recording,
            recorderState: .idle,
            previewActive: true
        )
        XCTAssertEqual(recording.source, .dictation)

        let recorder = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .recording,
            previewActive: true
        )
        XCTAssertEqual(recorder.source, .recorder)

        let finalizing = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .finalizing,
            previewActive: true
        )
        XCTAssertEqual(finalizing.source, .dictation)
        XCTAssertEqual(finalizing.state, .idle)

        let off = IndicatorPresentationState.resolve(
            dictationState: .idle,
            recorderState: .idle,
            previewActive: false
        )
        XCTAssertEqual(off.source, .dictation)
        XCTAssertFalse(IndicatorPresentationState.shouldShow(visibility: .never, presentation: off))
    }

    func testPreviewSessionProducesSpeechLikeLevelsAndGrowingTranscript() {
        var levels: [Float] = []
        var time: TimeInterval = 0
        while time < 2.6 {
            levels.append(IndicatorPreviewSession.level(at: time))
            time += 1.0 / 30.0
        }
        XCTAssertTrue(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(levels.max() ?? 0, 0.4)
        XCTAssertLessThan(levels.min() ?? 1, 0.1)

        let text = "one two three"
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: 0, text: text), "")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: 0.4, text: text), "one")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: 1.1, text: text), "one two three")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: 3.0, text: text), "one two three")
        let cycle = 3 * IndicatorPreviewSession.wordInterval + IndicatorPreviewSession.holdDuration
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: cycle + 0.1, text: text), "")
    }

    func testPreviewTranscriptUnfoldsTextWithoutSpacesByCharacter() {
        let text = "こんにちは"
        let step = IndicatorPreviewSession.characterInterval

        XCTAssertEqual(IndicatorPreviewSession.transcript(at: 0, text: text), "")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: step * 2.5, text: text), "こん")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: step * 10, text: text), text)
    }

    func testPreviewTranscriptTreatsNegativeTimeAsStart() {
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: -5, text: "one two"), "")
        XCTAssertEqual(IndicatorPreviewSession.transcript(at: -0.01, text: "one"), "")
    }

    func testBluetoothPreparationUsesSharedPreparingMicrophonePresentation() {
        let preparing = makeRecordingPresentation(isInputReady: false)
        let ready = makeRecordingPresentation(isInputReady: true)

        XCTAssertTrue(preparing.isPreparingMicrophone)
        XCTAssertEqual(preparing.recordingStatusLabel, String(localized: "Preparing microphone"))
        XCTAssertFalse(ready.isPreparingMicrophone)
        XCTAssertEqual(ready.recordingStatusLabel, String(localized: "Recording"))
    }

    func testModelLoadingLabelFollowsMicrophonePreparation() {
        let preparing = makeRecordingPresentation(isInputReady: false, isModelLoading: true)
        let loading = makeRecordingPresentation(isInputReady: true, isModelLoading: true)
        let ready = makeRecordingPresentation(isInputReady: true)

        XCTAssertEqual(preparing.recordingStatusLabel, String(localized: "Preparing microphone"))
        XCTAssertEqual(loading.modelLoadingLabel, IndicatorPresentationData.loadingModelText)
        XCTAssertEqual(loading.recordingStatusLabel, IndicatorPresentationData.loadingModelText)
        XCTAssertNil(ready.modelLoadingLabel)
    }

    func testNeverVisibilityStillSuppressesMicrophonePreparation() {
        let preparing = IndicatorPresentationState.resolve(
            dictationState: .recording,
            recorderState: .idle
        )

        XCTAssertFalse(IndicatorPresentationState.shouldShow(
            visibility: .never,
            presentation: preparing
        ))
    }

    func testFeedbackPresentationCarriesCountdownAndPauseState() {
        let presentation = makeFeedbackPresentation(
            remainingFraction: 0.625,
            isPaused: true
        )

        XCTAssertEqual(presentation.actionFeedbackRemainingFraction, 0.625)
        XCTAssertTrue(presentation.actionFeedbackIsPaused)
    }

    func testRegularRecordingPresentationDoesNotExposeFeedbackCountdown() {
        XCTAssertNil(
            makeRecordingPresentation(isInputReady: true)
                .actionFeedbackRemainingFraction
        )
    }
}

@MainActor
final class IndicatorFeedbackLifetimeTests: XCTestCase {
    func testCountdownUsesElapsedContinuousTimeAndExpiresOnce() {
        let clock = IndicatorFeedbackTestClock(now: 100)
        var expirationCount = 0
        let lifetime = makeLifetime(clock: clock)
        defer { lifetime.cancel() }

        lifetime.start(duration: 10) {
            expirationCount += 1
        }
        XCTAssertEqual(lifetime.remainingFraction, 1)

        clock.now = 102.5
        lifetime.updateRemainingTime()
        XCTAssertEqual(lifetime.remainingFraction, 0.75, accuracy: 0.0001)

        clock.now = 110
        lifetime.updateRemainingTime()
        lifetime.updateRemainingTime()
        XCTAssertEqual(lifetime.remainingFraction, 0)
        XCTAssertEqual(expirationCount, 1)
    }

    func testHoverPausesAndResumesFromRemainingTime() {
        let clock = IndicatorFeedbackTestClock()
        let lifetime = makeLifetime(clock: clock)
        defer { lifetime.cancel() }

        lifetime.start(duration: 10) {}
        clock.now = 2
        lifetime.setHovered(true)
        lifetime.setHovered(true)
        XCTAssertTrue(lifetime.isPaused)
        XCTAssertEqual(lifetime.remainingFraction, 0.8, accuracy: 0.0001)

        clock.now = 8
        lifetime.updateRemainingTime()
        XCTAssertEqual(lifetime.remainingFraction, 0.8, accuracy: 0.0001)

        lifetime.setHovered(false)
        lifetime.setHovered(false)
        clock.now = 10
        lifetime.updateRemainingTime()
        XCTAssertFalse(lifetime.isPaused)
        XCTAssertEqual(lifetime.remainingFraction, 0.6, accuracy: 0.0001)
    }

    func testRestartCancelsPreviousExpiration() {
        let clock = IndicatorFeedbackTestClock()
        var firstExpirationCount = 0
        var secondExpirationCount = 0
        let lifetime = makeLifetime(clock: clock)
        defer { lifetime.cancel() }

        lifetime.start(duration: 10) {
            firstExpirationCount += 1
        }
        clock.now = 3
        lifetime.updateRemainingTime()

        lifetime.start(duration: 4) {
            secondExpirationCount += 1
        }
        XCTAssertEqual(lifetime.remainingFraction, 1)

        clock.now = 7
        lifetime.updateRemainingTime()
        XCTAssertEqual(firstExpirationCount, 0)
        XCTAssertEqual(secondExpirationCount, 1)
    }

    func testCancelPreventsExpiration() {
        let clock = IndicatorFeedbackTestClock()
        var expirationCount = 0
        let lifetime = makeLifetime(clock: clock)

        lifetime.start(duration: 2) {
            expirationCount += 1
        }
        lifetime.cancel()
        clock.now = 5
        lifetime.updateRemainingTime()

        XCTAssertEqual(expirationCount, 0)
        XCTAssertEqual(lifetime.remainingFraction, 0)
        XCTAssertFalse(lifetime.isPaused)
    }

    func testFinishImmediatelyOverridesHoverPause() {
        let clock = IndicatorFeedbackTestClock()
        var expirationCount = 0
        let lifetime = makeLifetime(clock: clock)
        defer { lifetime.cancel() }

        lifetime.start(duration: 12) {
            expirationCount += 1
        }
        clock.now = 1
        lifetime.setHovered(true)
        lifetime.finishImmediately()
        lifetime.finishImmediately()

        XCTAssertEqual(expirationCount, 1)
        XCTAssertEqual(lifetime.remainingFraction, 0)
        XCTAssertFalse(lifetime.isPaused)
    }

    func testKnownFeedbackDurationsRetainTheirOwnCountdownScale() {
        for duration in [2.5, 3.0, 12.0, 7.25] {
            let clock = IndicatorFeedbackTestClock()
            let lifetime = makeLifetime(clock: clock)

            lifetime.start(duration: duration) {}
            clock.now = duration / 2
            lifetime.updateRemainingTime()

            XCTAssertEqual(
                lifetime.remainingFraction,
                0.5,
                accuracy: 0.0001,
                "Unexpected progress for duration \(duration)"
            )
            lifetime.cancel()
        }
    }

    private func makeLifetime(
        clock: IndicatorFeedbackTestClock
    ) -> IndicatorFeedbackLifetime {
        IndicatorFeedbackLifetime(
            tickInterval: .seconds(60),
            now: { clock.now },
            sleep: { _ in
                try await Task.sleep(for: .seconds(60))
            }
        )
    }
}

@MainActor
private final class IndicatorFeedbackTestClock {
    var now: TimeInterval

    init(now: TimeInterval = 0) {
        self.now = now
    }
}

@MainActor
final class IndicatorPanelInteractionTests: XCTestCase {
    func testOnlyVisibleInsertingFeedbackIsInteractive() {
        XCTAssertTrue(IndicatorFeedbackPanelLayout.isInteractive(
            state: .inserting,
            message: "Saved"
        ))
        XCTAssertFalse(IndicatorFeedbackPanelLayout.isInteractive(
            state: .inserting,
            message: nil
        ))
        XCTAssertFalse(IndicatorFeedbackPanelLayout.isInteractive(
            state: .recording,
            message: "Stale"
        ))
        XCTAssertFalse(IndicatorFeedbackPanelLayout.isInteractive(
            state: .processing,
            message: "Stale"
        ))
    }

    func testInteractiveFramesMatchVisibleFeedbackSurfaces() {
        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .notch,
                isFeedbackInteractive: true,
                notchClosedWidth: 305,
                notchClosedHeight: 30
            ),
            CGSize(width: 340, height: 82)
        )
        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .overlay,
                isFeedbackInteractive: true
            ),
            CGSize(width: 340, height: 100)
        )
        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .minimal,
                isFeedbackInteractive: true
            ),
            CGSize(width: 360, height: 52)
        )

        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .notch,
                isFeedbackInteractive: false
            ),
            CGSize(width: 500, height: 500)
        )
        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .overlay,
                isFeedbackInteractive: false
            ),
            CGSize(width: 500, height: 300)
        )
        XCTAssertEqual(
            IndicatorFeedbackPanelLayout.panelSize(
                for: .minimal,
                isFeedbackInteractive: false
            ),
            CGSize(width: 420, height: 160)
        )
    }

    func testShortFeedbackKeepsCompactBody() {
        for style in [IndicatorStyle.notch, .overlay, .minimal] {
            let body = IndicatorFeedbackPanelLayout.feedbackBody(for: style, message: "Copied to clipboard")

            XCTAssertEqual(body.height, IndicatorFeedbackPanelLayout.feedbackBodyHeight)
            XCTAssertEqual(body.lineLimit, 2)
            XCTAssertEqual(
                IndicatorFeedbackPanelLayout.panelSize(
                    for: style,
                    isFeedbackInteractive: true,
                    feedbackMessage: "Copied to clipboard"
                ),
                IndicatorFeedbackPanelLayout.panelSize(for: style, isFeedbackInteractive: true)
            )
        }
    }

    func testLongFeedbackWidensAndGrowsWithTheMessage() {
        let message = "API error: HTTP 429: You are using a Trial key, which is limited to 1000 API calls / month. "
            + "You can continue to use the Trial key for free or upgrade to a Production key with higher rate limits."

        for style in [IndicatorStyle.notch, .overlay, .minimal] {
            let body = IndicatorFeedbackPanelLayout.feedbackBody(for: style, message: message)
            let panelSize = IndicatorFeedbackPanelLayout.panelSize(
                for: style,
                isFeedbackInteractive: true,
                notchClosedHeight: 30,
                feedbackMessage: message
            )

            XCTAssertEqual(body.width, IndicatorFeedbackPanelLayout.wideFeedbackWidth)
            XCTAssertGreaterThan(body.height, IndicatorFeedbackPanelLayout.feedbackBodyHeight)
            XCTAssertGreaterThan(body.lineLimit, 2)
            XCTAssertLessThanOrEqual(body.lineLimit, IndicatorFeedbackPanelLayout.feedbackMaximumLineCount)
            XCTAssertEqual(panelSize.width, body.width)
            XCTAssertGreaterThanOrEqual(panelSize.height, body.height)
        }
    }

    func testFeedbackGrowthStopsAtMaximumLineCount() {
        let message = String(repeating: "provider message ", count: 200)

        let body = IndicatorFeedbackPanelLayout.feedbackBody(for: .overlay, message: message)
        let longer = IndicatorFeedbackPanelLayout.feedbackBody(for: .overlay, message: message + message)

        XCTAssertEqual(body.lineLimit, IndicatorFeedbackPanelLayout.feedbackMaximumLineCount)
        XCTAssertEqual(body, longer)
    }

    func testErrorFeedbackDurationGrowsWithMessageLength() {
        XCTAssertEqual(DictationViewModel.errorFeedbackDuration(message: "Short", baseDuration: 3), 3)
        XCTAssertEqual(DictationViewModel.errorFeedbackDuration(message: "Short", baseDuration: 8), 8)
        XCTAssertEqual(
            DictationViewModel.errorFeedbackDuration(message: String(repeating: "a", count: 150), baseDuration: 3),
            6
        )
        XCTAssertEqual(
            DictationViewModel.errorFeedbackDuration(message: String(repeating: "a", count: 5_000), baseDuration: 3),
            12
        )
    }

    func testOverlaySurfaceClipsFeedbackProgressToRoundedWindow() throws {
        let width = Int(IndicatorFeedbackPanelLayout.feedbackWidth)
        let height = Int(
            IndicatorFeedbackPanelLayout.overlayStatusHeight
                + IndicatorFeedbackPanelLayout.feedbackBodyHeight
        )
        let renderer = ImageRenderer(
            content: OverlayIndicatorSurface {
                Color.clear
                    .frame(width: CGFloat(width), height: CGFloat(height))
                    .overlay(alignment: .top) {
                        Color.red.frame(height: 2)
                    }
            }
        )
        renderer.proposedSize = ProposedViewSize(
            width: CGFloat(width),
            height: CGFloat(height)
        )
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let leftEdgeRed = try XCTUnwrap([
            XCTUnwrap(bitmap.colorAt(x: 0, y: 0)),
            XCTUnwrap(bitmap.colorAt(x: 0, y: height - 1))
        ]
        .map(\.redComponent)
        .max())
        let centerEdgeRed = try XCTUnwrap([
            XCTUnwrap(bitmap.colorAt(x: width / 2, y: 0)),
            XCTUnwrap(bitmap.colorAt(x: width / 2, y: height - 1))
        ]
        .map(\.redComponent)
        .max())

        XCTAssertLessThan(leftEdgeRed, 0.2)
        XCTAssertGreaterThan(centerEdgeRed, 0.8)
    }

    func testMinimalSurfaceKeepsProgressVisibleNearExpiration() throws {
        let width = Int(IndicatorFeedbackPanelLayout.minimalFeedbackWidth)
        let height = Int(IndicatorFeedbackPanelLayout.feedbackBodyHeight)
        let renderer = ImageRenderer(
            content: VStack(spacing: 0) {
                MinimalIndicatorFeedbackProgress(remainingFraction: 0.02)
                Color.clear
            }
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(.black.opacity(0.84), in: Capsule())
            .clipShape(Capsule())
            // The progress bar uses the semantic primary color, which the
            // classic surface resolves in the dark scheme.
            .environment(\.colorScheme, .dark)
        )
        renderer.proposedSize = ProposedViewSize(
            width: CGFloat(width),
            height: CGFloat(height)
        )
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let progressX = Int(
            IndicatorFeedbackPanelLayout.minimalFeedbackProgressHorizontalInset
        ) + 1
        let progressColor = try XCTUnwrap(
            bitmap.colorAt(x: progressX, y: 0)?.usingColorSpace(.deviceRGB)
        )
        let outsideColor = try XCTUnwrap(
            bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
        )

        XCTAssertGreaterThan(progressColor.redComponent, 0.5)
        XCTAssertLessThan(outsideColor.alphaComponent, 0.1)
    }

    func testFeedbackFramePreservesStyleAnchor() {
        let screenFrame = CGRect(x: 100, y: 200, width: 1_000, height: 800)

        let passiveNotch = frame(for: .notch, interactive: false, in: screenFrame)
        let feedbackNotch = frame(for: .notch, interactive: true, in: screenFrame)
        XCTAssertEqual(passiveNotch.maxY, feedbackNotch.maxY)
        XCTAssertEqual(feedbackNotch.maxY, screenFrame.maxY)

        let passiveTop = frame(for: .overlay, interactive: false, in: screenFrame, position: .top)
        let feedbackTop = frame(for: .overlay, interactive: true, in: screenFrame, position: .top)
        XCTAssertEqual(passiveTop.maxY, feedbackTop.maxY)
        XCTAssertEqual(feedbackTop.maxY, screenFrame.maxY - 20)

        let passiveBottom = frame(for: .minimal, interactive: false, in: screenFrame, position: .bottom)
        let feedbackBottom = frame(for: .minimal, interactive: true, in: screenFrame, position: .bottom)
        XCTAssertEqual(passiveBottom.minY, feedbackBottom.minY)
        XCTAssertEqual(feedbackBottom.minY, screenFrame.minY + 20)
    }

    func testAllPanelsRemainNonactivatingAndPassiveWhenHidden() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Indicator panel tests require an available screen")
        }
        let resolver = makeResolver(screen: screen)
        let notch = NotchIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            content: { _ in EmptyView() }
        )
        let overlay = OverlayIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            content: { EmptyView() }
        )
        let minimal = MinimalIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            content: { EmptyView() }
        )
        let panels: [NSPanel] = [notch, overlay, minimal]
        defer { panels.forEach { $0.orderOut(nil) } }

        notch.updateFeedbackInteraction(isInteractive: true)
        overlay.updateFeedbackInteraction(isInteractive: true)
        minimal.updateFeedbackInteraction(isInteractive: true)

        for panel in panels {
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.ignoresMouseEvents)
        }
    }

    private func frame(
        for style: IndicatorStyle,
        interactive: Bool,
        in screenFrame: CGRect,
        position: OverlayPosition = .top
    ) -> CGRect {
        let size = IndicatorFeedbackPanelLayout.panelSize(
            for: style,
            isFeedbackInteractive: interactive,
            notchClosedWidth: 305,
            notchClosedHeight: 30
        )
        return IndicatorFeedbackPanelLayout.panelFrame(
            for: style,
            size: size,
            in: screenFrame,
            overlayPosition: position
        )
    }

    private func makeResolver(screen: NSScreen) -> IndicatorScreenResolver {
        IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )
    }
}

@MainActor
private final class NotchLayoutProbeModel: ObservableObject {
    @Published var feedback = false
    var rootSizes: [CGSize] = []
    var safeArea: EdgeInsets?
}

private struct NotchLayoutProbeView: View {
    @ObservedObject var model: NotchLayoutProbeModel

    var body: some View {
        GeometryReader { geometry in
            Color.black
                .frame(width: model.feedback ? 340 : 400, height: model.feedback ? 86 : 160)
                .animation(.easeOut(duration: 0.24), value: model.feedback)
                .onAppear {
                    model.rootSizes.append(geometry.size)
                    model.safeArea = geometry.safeAreaInsets
                }
                .onChange(of: geometry.size) { model.rootSizes.append(geometry.size) }
                .onChange(of: geometry.safeAreaInsets) { model.safeArea = geometry.safeAreaInsets }
        }
    }
}

@MainActor
final class NotchIndicatorPanelLifecycleTests: XCTestCase {
    func testFixedHostingViewRemainsCenteredAndTopAlignedWhilePanelResizes() throws {
        let panel = try makePanel()
        defer { panel.orderOut(nil) }
        let container = try XCTUnwrap(panel.contentView)
        let hostingView = try XCTUnwrap(container.subviews.first)
        let fixedSize = CGSize(width: 500, height: 500)

        for size in [
            CGSize(width: 340, height: 86),
            fixedSize,
            CGSize(width: 360, height: 90),
            CGSize(width: 640, height: 120),
            fixedSize
        ] {
            let frame = CGRect(origin: CGPoint(x: 100, y: 200), size: size)
            panel.setFrame(frame, display: false)
            panel.layoutIfNeeded()

            XCTAssertEqual(panel.frame, frame)
            XCTAssertEqual(hostingView.frame.size, fixedSize)
            XCTAssertEqual(hostingView.bounds.size, fixedSize)
            XCTAssertEqual(hostingView.frame.midX, container.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(hostingView.frame.maxY, container.bounds.maxY, accuracy: 0.01)
        }
    }

    func testFeedbackTransitionsKeepSwiftUIRootSizeAndIgnoreSystemSafeArea() async throws {
        let model = NotchLayoutProbeModel()
        let panel = try makePanel { _ in NotchLayoutProbeView(model: model) }
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }
        panel.show()
        let container = try XCTUnwrap(panel.contentView)

        for interactive in [false, true, false, true, false] {
            withAnimation(.easeOut(duration: 0.24)) {
                model.feedback = interactive
                panel.updateFeedbackInteraction(isInteractive: interactive)
            }
            let expectedFrame = panel.frame
            for inset in [CGFloat(32), 64, 0] {
                container.additionalSafeAreaInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
                panel.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))

                XCTAssertFalse(model.rootSizes.isEmpty)
                XCTAssertTrue(model.rootSizes.allSatisfy { $0 == CGSize(width: 500, height: 500) })
                XCTAssertEqual(model.safeArea, EdgeInsets())
                XCTAssertEqual(panel.frame, expectedFrame)
                XCTAssertFalse(panel.canBecomeKey)
                XCTAssertFalse(panel.canBecomeMain)
            }
        }
    }

    func testPlacementRefreshDoesNotCancelInFlightDismissal() async throws {
        let panel = try makePanel()
        defer { panel.orderOut(nil) }

        panel.show()
        await Task.yield()
        XCTAssertTrue(panel.isVisible)

        panel.dismiss()
        panel.refreshPlacementForActiveContextChange()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(panel.isVisible)
    }

    func testShowCancelsInFlightDismissalForNewActivity() async throws {
        let panel = try makePanel()
        defer { panel.orderOut(nil) }

        panel.show()
        await Task.yield()
        XCTAssertTrue(panel.isVisible)

        panel.dismiss()
        panel.show()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(panel.isVisible)
    }

    func testFeedbackInteractionChangeDoesNotCancelInFlightDismissal() async throws {
        let panel = try makePanel()
        defer { panel.orderOut(nil) }

        panel.show()
        await Task.yield()
        panel.updateFeedbackInteraction(isInteractive: true)
        XCTAssertTrue(panel.isVisible)

        // Dictation ends while an action-feedback toast is up: the state sink
        // dismisses, then the feedback sink flips interaction back off inside
        // the dismissal animation window. That second callback must not
        // resurrect the panel — previously it cancelled the pending orderOut
        // and left a blank window stuck over the notch.
        panel.dismiss()
        panel.updateFeedbackInteraction(isInteractive: false)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(panel.isVisible)
    }

    func testShowAfterFeedbackInteractionChangeDuringDismissalStillPresents() async throws {
        let panel = try makePanel()
        defer { panel.orderOut(nil) }

        panel.show()
        await Task.yield()
        panel.dismiss()
        panel.updateFeedbackInteraction(isInteractive: true)
        panel.show()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(panel.isVisible)
    }

    private func makePanel() throws -> NotchIndicatorPanel {
        try makePanel { _ in EmptyView() }
    }

    private func makePanel<Content: View>(
        @ViewBuilder content: (NotchGeometry) -> Content
    ) throws -> NotchIndicatorPanel {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Notch indicator panel tests require an available screen")
        }

        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )
        return NotchIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            content: content
        )
    }
}

@MainActor
final class FloatingIndicatorPanelHostingTests: XCTestCase {
    private static let longMessage = String(repeating: "The provider rejected the request. ", count: 30)

    func testOverlayFeedbackTransitionsKeepSwiftUIRootSizeAndIgnoreSystemSafeArea() async throws {
        let model = NotchLayoutProbeModel()
        let panel = OverlayIndicatorPanel(
            screenResolver: try makeResolver(),
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            content: { NotchLayoutProbeView(model: model) }
        )
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }
        panel.show()

        try await assertRootSizeStaysConstant(model: model, panel: panel) { interactive, message in
            panel.updateFeedbackInteraction(isInteractive: interactive, message: message)
        }
    }

    func testMinimalFeedbackTransitionsKeepSwiftUIRootSizeAndIgnoreSystemSafeArea() async throws {
        let model = NotchLayoutProbeModel()
        let panel = MinimalIndicatorPanel(
            screenResolver: try makeResolver(),
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            content: { NotchLayoutProbeView(model: model) }
        )
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }
        panel.show()

        try await assertRootSizeStaysConstant(model: model, panel: panel) { interactive, message in
            panel.updateFeedbackInteraction(isInteractive: interactive, message: message)
        }
    }

    func testHostingSizeCoversPassivePanelAndLargestFeedback() {
        for style in [IndicatorStyle.overlay, .minimal] {
            let hostingSize = IndicatorFeedbackPanelLayout.hostingSize(for: style)
            let sizes = [
                IndicatorFeedbackPanelLayout.panelSize(for: style, isFeedbackInteractive: false),
                IndicatorFeedbackPanelLayout.panelSize(for: style, isFeedbackInteractive: true),
                IndicatorFeedbackPanelLayout.panelSize(
                    for: style,
                    isFeedbackInteractive: true,
                    feedbackMessage: Self.longMessage,
                    feedbackActionTitle: "Undo"
                )
            ]
            for size in sizes {
                XCTAssertGreaterThanOrEqual(hostingSize.width, size.width, "\(style)")
                XCTAssertGreaterThanOrEqual(hostingSize.height, size.height, "\(style)")
            }
        }
    }

    func testOverlayHostingViewKeepsItsSizeAndFollowsOverlayPosition() throws {
        var position = OverlayPosition.top
        let panel = OverlayIndicatorPanel(
            screenResolver: try makeResolver(),
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { position },
            content: { EmptyView() }
        )
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }

        try assertHostingViewStaysFixed(
            panel: panel,
            size: IndicatorFeedbackPanelLayout.hostingSize(for: .overlay)
        ) { newPosition, interactive, message in
            position = newPosition
            panel.updateFeedbackInteraction(isInteractive: interactive, message: message)
            panel.show()
        }
    }

    func testMinimalHostingViewKeepsItsSizeAndFollowsOverlayPosition() throws {
        var position = OverlayPosition.top
        let panel = MinimalIndicatorPanel(
            screenResolver: try makeResolver(),
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { position },
            content: { EmptyView() }
        )
        panel.alphaValue = 0
        defer { panel.orderOut(nil) }

        try assertHostingViewStaysFixed(
            panel: panel,
            size: IndicatorFeedbackPanelLayout.hostingSize(for: .minimal)
        ) { newPosition, interactive, message in
            position = newPosition
            panel.updateFeedbackInteraction(isInteractive: interactive, message: message)
            panel.show()
        }
    }

    private func assertHostingViewStaysFixed(
        panel: NSPanel,
        size: CGSize,
        update: (OverlayPosition, Bool, String?) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        update(.top, false, nil)
        try XCTSkipUnless(panel.isVisible, "Indicator panel is suppressed on this screen")
        let container = try XCTUnwrap(panel.contentView)
        let hostingView = try XCTUnwrap(container.subviews.first, file: file, line: line)

        let steps: [(OverlayPosition, Bool, String?)] = [
            (.top, true, "Undid last dictation"),
            (.top, true, Self.longMessage),
            (.bottom, true, Self.longMessage),
            (.bottom, false, nil),
            (.bottom, true, "Undid last dictation"),
            (.top, false, nil)
        ]
        for (position, interactive, message) in steps {
            update(position, interactive, message)
            panel.layoutIfNeeded()

            XCTAssertEqual(hostingView.frame.size, size, file: file, line: line)
            XCTAssertEqual(hostingView.bounds.size, size, file: file, line: line)
            XCTAssertEqual(hostingView.frame.midX, container.bounds.midX, accuracy: 0.01, file: file, line: line)
            switch position {
            case .top:
                XCTAssertEqual(hostingView.frame.maxY, container.bounds.maxY, accuracy: 0.01, file: file, line: line)
            case .bottom:
                XCTAssertEqual(hostingView.frame.minY, container.bounds.minY, accuracy: 0.01, file: file, line: line)
            }
        }
    }

    private func assertRootSizeStaysConstant(
        model: NotchLayoutProbeModel,
        panel: NSPanel,
        updateFeedback: (Bool, String?) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try XCTSkipUnless(panel.isVisible, "Indicator panel is suppressed on this screen")
        let container = try XCTUnwrap(panel.contentView)

        // Undo feedback, the next dictation, then a long provider error (#1441).
        let steps: [(Bool, String?)] = [
            (true, "Undid last dictation"),
            (false, nil),
            (true, Self.longMessage),
            (true, "Undid last dictation"),
            (false, nil)
        ]
        var panelSizes = Set<String>()
        for (interactive, message) in steps {
            withAnimation(.easeOut(duration: 0.24)) {
                model.feedback = interactive
                updateFeedback(interactive, message)
            }
            let expectedFrame = panel.frame
            panelSizes.insert("\(expectedFrame.size)")
            for inset in [CGFloat(32), 0] {
                container.additionalSafeAreaInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
                panel.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(panel.frame, expectedFrame, file: file, line: line)
            }
        }

        XCTAssertGreaterThan(panelSizes.count, 2, "The panel frame must follow the feedback", file: file, line: line)
        XCTAssertFalse(model.rootSizes.isEmpty, file: file, line: line)
        XCTAssertEqual(
            Set(model.rootSizes.map { "\($0)" }).count,
            1,
            "SwiftUI root resized with the panel: \(model.rootSizes)",
            file: file,
            line: line
        )
        XCTAssertEqual(model.safeArea, EdgeInsets(), file: file, line: line)
    }

    private func makeResolver() throws -> IndicatorScreenResolver {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Indicator panel tests require an available screen")
        }
        return IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )
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

    @MainActor
    func testCachedImagesAreReusedAcrossStateChanges() {
        XCTAssertTrue(
            MenuBarLogoMarkImage.cachedImage(isRecordingActive: false)
                === MenuBarLogoMarkImage.cachedImage(isRecordingActive: false)
        )
        XCTAssertTrue(
            MenuBarLogoMarkImage.cachedImage(isRecordingActive: true)
                === MenuBarLogoMarkImage.cachedImage(isRecordingActive: true)
        )
        XCTAssertFalse(MenuBarLogoMarkImage.cachedImage(isRecordingActive: true).isTemplate)
        XCTAssertTrue(
            MenuBarLogoMarkImage.cachedImage(isRecordingActive: true, increaseContrast: true)
                === MenuBarLogoMarkImage.cachedImage(isRecordingActive: true, increaseContrast: true)
        )
        XCTAssertTrue(
            MenuBarLogoMarkImage.cachedImage(isRecordingActive: false, increaseContrast: true)
                === MenuBarLogoMarkImage.cachedImage(isRecordingActive: false)
        )
    }

    /// Compares only the alpha channel, so the result does not depend on color:
    /// the recording icon must have a different silhouette, not just a red tint.
    func testRecordingIconFillsTheAreaAroundTheBarsSoItsShapeChanges() throws {
        let slot = CGRect(origin: .zero, size: MenuBarLogoMarkImage.size)
        // The gaps between the idle bars and the margin around them, kept inside
        // the badge's rounded corners and clear of anti-aliased bar edges.
        let barArea = MenuBarLogoMarkImage.barRects(in: slot).map { $0.insetBy(dx: -0.5, dy: -0.5) }
        let badgeInterior = NSBezierPath(
            roundedRect: MenuBarLogoMarkImage.recordingBadgeRect(in: slot).insetBy(dx: 1, dy: 1),
            xRadius: 3,
            yRadius: 3
        )
        let isAroundTheBars: (CGPoint) -> Bool = { point in
            badgeInterior.contains(point) && !barArea.contains { $0.contains(point) }
        }

        for increaseContrast in [false, true] {
            let idle = try Self.renderedPixels(MenuBarLogoMarkImage.image(isRecordingActive: false))
            let recording = try Self.renderedPixels(
                MenuBarLogoMarkImage.image(isRecordingActive: true, increaseContrast: increaseContrast)
            )

            XCTAssertLessThan(idle.alphaCoverage(where: isAroundTheBars), 0.01, "Idle icon draws outside its bars")
            XCTAssertGreaterThan(
                recording.alphaCoverage(where: isAroundTheBars),
                0.99,
                "Recording icon does not fill the area around the bars"
            )
            XCTAssertGreaterThan(
                recording.alphaCoverage { _ in true },
                idle.alphaCoverage { _ in true } * 2
            )
        }
    }

    /// The bars must stay visible inside the badge: white bars with at least the
    /// 3:1 contrast WCAG asks for graphics, and 4.5:1 with Increase Contrast.
    func testRecordingBadgeKeepsTheBarsLegible() throws {
        let slot = CGRect(origin: .zero, size: MenuBarLogoMarkImage.size)
        let badge = MenuBarLogoMarkImage.recordingBadgeRect(in: slot)
        let bars = MenuBarLogoMarkImage.recordingBarRects(in: slot)

        XCTAssertEqual(bars.count, 5)
        for bar in bars {
            XCTAssertTrue(badge.insetBy(dx: 1, dy: 1).contains(bar))
        }

        for increaseContrast in [false, true] {
            let pixels = try Self.renderedPixels(
                MenuBarLogoMarkImage.image(isRecordingActive: true, increaseContrast: increaseContrast)
            )
            let middleBar = bars[2]
            let barCenter = CGPoint(x: middleBar.midX, y: middleBar.midY)
            let gapCenter = CGPoint(x: (bars[1].maxX + bars[2].minX) / 2, y: middleBar.midY)
            let badgeMargin = CGPoint(x: badge.minX + 1, y: badge.midY)

            XCTAssertEqual(pixels.alpha(at: barCenter), 1, accuracy: 0.01)
            XCTAssertEqual(pixels.alpha(at: badgeMargin), 1, accuracy: 0.01)
            XCTAssertGreaterThan(pixels.relativeLuminance(at: barCenter), 0.95)

            let barContrast = (pixels.relativeLuminance(at: barCenter) + 0.05)
                / (pixels.relativeLuminance(at: badgeMargin) + 0.05)
            XCTAssertGreaterThanOrEqual(barContrast, increaseContrast ? 4.5 : 3, "Contrast \(barContrast)")
            XCTAssertLessThan(pixels.relativeLuminance(at: gapCenter), pixels.relativeLuminance(at: barCenter))
        }
    }

    /// The icon drawn at 2x into an sRGB bitmap.
    private struct RenderedPixels {
        let bitmap: NSBitmapImageRep
        let scale: CGFloat

        func alphaCoverage(where include: (CGPoint) -> Bool) -> Double {
            var covered = 0.0
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    // Pixel centers in image points, with y growing upwards as in the drawing.
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / scale,
                        y: (CGFloat(bitmap.pixelsHigh - 1 - y) + 0.5) / scale
                    )
                    guard include(point) else { continue }
                    count += 1
                    covered += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            return count == 0 ? 0 : covered / Double(count)
        }

        func alpha(at point: CGPoint) -> Double {
            Double(color(at: point)?.alphaComponent ?? 0)
        }

        /// WCAG relative luminance of the sRGB pixel.
        func relativeLuminance(at point: CGPoint) -> Double {
            guard let color = color(at: point)?.usingColorSpace(.sRGB) else { return 0 }
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }

        private func color(at point: CGPoint) -> NSColor? {
            let x = Int(point.x * scale)
            let y = bitmap.pixelsHigh - 1 - Int(point.y * scale)
            return bitmap.colorAt(x: x, y: y)
        }
    }

    private static func renderedPixels(_ image: NSImage, scale: CGFloat = 2) throws -> RenderedPixels {
        let size = image.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )?.retagging(with: .sRGB))
        bitmap.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return RenderedPixels(bitmap: bitmap, scale: scale)
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

    func testPreparingMicrophoneHasGermanLocalization() throws {
        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(
                for: "Preparing microphone",
                language: "de"
            ),
            "Mikrofon wird vorbereitet …"
        )
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

    func testLocalizedAppTextFindsSpanishInTheCatalogOrInline() throws {
        UserDefaults.standard.set("es", forKey: UserDefaultsKeys.preferredAppLanguage)

        // Plain English text is looked up in the catalog like Japanese and Chinese.
        let catalogSpanish = try TestSupport.localizedCatalogValue(for: "Multilingual", language: "es")
        XCTAssertNotEqual(catalogSpanish, "Multilingual")
        XCTAssertEqual(localizedAppLanguageName(for: "multi"), catalogSpanish)

        // Text with interpolated values can't be found that way and carries its Spanish inline.
        let count = 3
        XCTAssertEqual(
            localizedAppText("More Models (\(count))", de: "Weitere Modelle (\(count))", es: "Más modelos (\(count))"),
            "Más modelos (3)"
        )
        XCTAssertEqual(
            localizedAppText("More Models (\(count))", de: "Weitere Modelle (\(count))"),
            "More Models (3)"
        )

        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(
            localizedAppText("More Models (\(count))", de: "Weitere Modelle (\(count))", es: "Más modelos (\(count))"),
            "Weitere Modelle (3)"
        )
    }

    func testLocalizedAppTextFindsTraditionalChineseInTheCatalogOrInline() throws {
        UserDefaults.standard.set("zh-Hant", forKey: UserDefaultsKeys.preferredAppLanguage)

        // Plain English text is looked up in the zh-Hant catalog, not the Simplified one.
        let catalogTraditional = try TestSupport.localizedCatalogValue(for: "Multilingual", language: "zh-Hant")
        let catalogSimplified = try TestSupport.localizedCatalogValue(for: "Multilingual", language: "zh-Hans")
        XCTAssertNotEqual(catalogTraditional, "Multilingual")
        XCTAssertNotEqual(catalogTraditional, catalogSimplified)
        XCTAssertEqual(localizedAppLanguageName(for: "multi"), catalogTraditional)

        // Inline Traditional Chinese wins over inline Simplified Chinese.
        let count = 3
        XCTAssertEqual(
            localizedAppText(
                "More Models (\(count))",
                de: "Weitere Modelle (\(count))",
                zh: "更多模型（\(count)）",
                zhHant: "更多模型（共 \(count) 個）"
            ),
            "更多模型（共 3 個）"
        )

        UserDefaults.standard.set("zh-Hans", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(
            localizedAppText(
                "More Models (\(count))",
                de: "Weitere Modelle (\(count))",
                zh: "更多模型（\(count)）",
                zhHant: "更多模型（共 \(count) 個）"
            ),
            "更多模型（3）"
        )
    }

    func testTraditionalChineseLanguageCodes() {
        for code in ["zh-Hant", "zh-Hant-TW", "zh-Hant-HK", "zh-TW", "zh_HK", "zh-MO"] {
            XCTAssertTrue(isTraditionalChineseLanguageCode(code), code)
        }
        for code in ["zh", "zh-Hans", "zh-Hans-HK", "zh-CN", "zh-SG", "ja", "en"] {
            XCTAssertFalse(isTraditionalChineseLanguageCode(code), code)
        }
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

@MainActor
final class IndicatorPointerTrackerTests: XCTestCase {
    private var panel: NSPanel!
    private var hostingView: NSView!

    override func setUp() async throws {
        panel = NSPanel(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        hostingView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        panel.contentView = hostingView
        panel.orderFront(nil)
    }

    override func tearDown() async throws {
        panel.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    func testSurfaceFrameMapsTopLeftRootCoordinatesToScreen() {
        let region = IndicatorPointerRegion()
        region.surfaceFrame = CGRect(x: 10, y: 0, width: 50, height: 20)
        let tracker = IndicatorPointerTracker(region: region, pointerLocationProvider: { .zero })
        tracker.hostingView = hostingView

        let frame = tracker.surfaceScreenFrame()

        XCTAssertEqual(frame.minX, panel.frame.minX + 10)
        XCTAssertEqual(frame.maxY, panel.frame.maxY)
        XCTAssertEqual(frame.size, CGSize(width: 50, height: 20))
    }

    func testPointerOverSurfaceIsReportedOnlyWhileActive() {
        let region = IndicatorPointerRegion()
        region.surfaceFrame = CGRect(x: 10, y: 0, width: 50, height: 20)
        var pointer = NSPoint(x: panel.frame.minX + 30, y: panel.frame.maxY - 10)
        let tracker = IndicatorPointerTracker(region: region, pointerLocationProvider: { pointer })
        tracker.hostingView = hostingView
        var changes = 0
        tracker.onChange = { changes += 1 }

        tracker.update()
        XCTAssertFalse(region.isPointerInside, "An inactive tracker never takes the pointer")

        tracker.setActive(true)
        XCTAssertTrue(region.isPointerInside, "Activation picks up a pointer already on the surface")
        XCTAssertEqual(changes, 1)

        // Transparent part of the panel, below the visible surface.
        pointer = NSPoint(x: panel.frame.minX + 30, y: panel.frame.minY + 10)
        tracker.update()
        XCTAssertFalse(region.isPointerInside)
        XCTAssertEqual(changes, 2)

        pointer = NSPoint(x: panel.frame.minX + 30, y: panel.frame.maxY - 10)
        tracker.update()
        XCTAssertTrue(region.isPointerInside)

        tracker.setActive(false)
        XCTAssertFalse(region.isPointerInside)
        XCTAssertEqual(changes, 4)
    }

    func testHiddenPanelNeverTakesThePointer() {
        let region = IndicatorPointerRegion()
        region.surfaceFrame = CGRect(x: 0, y: 0, width: 300, height: 100)
        let tracker = IndicatorPointerTracker(
            region: region,
            pointerLocationProvider: { [panel] in NSPoint(x: panel!.frame.midX, y: panel!.frame.midY) }
        )
        tracker.hostingView = hostingView
        panel.orderOut(nil)

        tracker.setActive(true)

        XCTAssertFalse(region.isPointerInside)
        tracker.setActive(false)
    }

    func testPassiveOverlayPanelStaysClickThrough() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Overlay indicator panel tests require an available screen")
        }
        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )
        let overlay = OverlayIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            content: { EmptyView() }
        )
        overlay.alphaValue = 0
        defer { overlay.dismiss() }
        overlay.show()

        XCTAssertTrue(overlay.ignoresMouseEvents, "The passive panel stays click-through")
        overlay.dismiss()
        XCTAssertTrue(overlay.ignoresMouseEvents)
    }
}
