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

    func testRecordingCancelConfirmationDefaultsToEnabled() {
        XCTAssertTrue(DictationViewModel.loadRequireSecondEscapeToCancelRecording(defaults: defaults))
    }

    func testRecordingCancelConfirmationPersistsWhenDisabled() {
        DictationViewModel.persistRequireSecondEscapeToCancelRecording(false, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.requireSecondEscapeToCancelRecording) as? Bool,
            false
        )
        XCTAssertFalse(DictationViewModel.loadRequireSecondEscapeToCancelRecording(defaults: defaults))
    }

    func testRecordingCancelConfirmationPersistsWhenEnabled() {
        DictationViewModel.persistRequireSecondEscapeToCancelRecording(true, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.requireSecondEscapeToCancelRecording) as? Bool,
            true
        )
        XCTAssertTrue(DictationViewModel.loadRequireSecondEscapeToCancelRecording(defaults: defaults))
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
    func testMenuBarSectionsUseExpectedOrderAndLocalizedKeys() {
        XCTAssertEqual(
            MenuBarMenuSection.allCases.map(\.titleLocalizationKey),
            ["General", "Transcription"]
        )
    }

    func testMenuBarSectionsContainExpectedItems() {
        XCTAssertEqual(
            MenuBarMenuSection.general.items,
            [.settings, .history, .errorLog]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: true),
            [.toggleDictationHotkeysPause, .transcribeFile, .recoverLastRecording, .lastTranscription]
        )
        XCTAssertEqual(
            MenuBarMenuSection.transcription.items(hasRecoverableRecording: false),
            [.toggleDictationHotkeysPause, .transcribeFile, .lastTranscription]
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
    private func makeRecordingPresentation(isInputReady: Bool) -> IndicatorPresentationData {
        IndicatorPresentationData(
            source: .dictation,
            state: .recording,
            recordingDuration: 0,
            audioLevel: 0,
            partialText: "",
            activeRuleName: nil,
            activeAppIcon: nil,
            isRecordingInputReady: isInputReady,
            cancelWarningMessage: nil,
            processingPhase: nil,
            actionFeedbackMessage: nil,
            actionFeedbackIcon: nil,
            actionFeedbackIsError: false,
            actionFeedbackUndoTitle: nil,
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
            cancelWarningMessage: nil,
            processingPhase: nil,
            actionFeedbackMessage: "Saved",
            actionFeedbackIcon: "checkmark.circle.fill",
            actionFeedbackIsError: false,
            actionFeedbackUndoTitle: "Undo",
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

    func testBluetoothPreparationUsesSharedPreparingMicrophonePresentation() {
        let preparing = makeRecordingPresentation(isInputReady: false)
        let ready = makeRecordingPresentation(isInputReady: true)

        XCTAssertTrue(preparing.isPreparingMicrophone)
        XCTAssertEqual(preparing.recordingStatusLabel, String(localized: "Preparing microphone"))
        XCTAssertFalse(ready.isPreparingMicrophone)
        XCTAssertEqual(ready.recordingStatusLabel, String(localized: "Recording"))
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
