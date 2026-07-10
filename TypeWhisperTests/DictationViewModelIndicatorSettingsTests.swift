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

    func testSuppressesSafariFullscreenLikeWindowWhenAXReportsNotFullscreen() {
        let safariFullscreenWindow = CGRect(x: 0, y: 0, width: 3024, height: 1964)

        XCTAssertTrue(
            IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                screenFrame: notchedScreenFrame,
                safeAreaTopInset: 74,
                windowFrame: safariFullscreenWindow,
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
                focusedWindowIsFullscreen: false,
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
                focusedWindowIsFullscreen: false,
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
                safariWindowFrames: [safariFullscreenWindow]
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
                safariWindowFrames: [safariFullscreenWindow]
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
                safariWindowFrames: [safariContentWindowBelowNotch]
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
                safariWindowFrames: [safariWindowBelowMenuBar]
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
            [.toggleDictationHotkeysPause, .transcribeFile, .recoverLastRecording, .recentTranscriptions, .copyLastTranscription, .readBackLastTranscription]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: false),
            [.toggleDictationHotkeysPause, .transcribeFile, .recentTranscriptions, .copyLastTranscription, .readBackLastTranscription]
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

@MainActor
final class NotchIndicatorPanelLifecycleTests: XCTestCase {
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

    private func makePanel() throws -> NotchIndicatorPanel {
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
            content: { _ in EmptyView() }
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
