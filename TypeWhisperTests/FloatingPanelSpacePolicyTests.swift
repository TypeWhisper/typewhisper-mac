import AppKit
import XCTest
@testable import TypeWhisper

final class FloatingPanelSpacePolicyTests: XCTestCase {
    func testActiveScreenIndicatorPolicyTargetsOnlyTheActiveNormalSpace() {
        let behavior = FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .activeScreen)

        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
    }

    func testFixedDisplayIndicatorPolicyStaysOnConfiguredDisplayAcrossNormalSpaces() {
        let primaryBehavior = FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .primaryScreen)
        let builtInBehavior = FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .builtInScreen)

        XCTAssertTrue(primaryBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(primaryBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(primaryBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(primaryBehavior.contains(.fullScreenNone))
        XCTAssertEqual(primaryBehavior, builtInBehavior)
    }

    func testActiveScreenIndicatorPolicyRemainsVisibleOverFullscreenApps() {
        XCTAssertTrue(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .activeScreen).contains(.fullScreenAuxiliary)
        )
        XCTAssertFalse(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .activeScreen).contains(.fullScreenNone)
        )
    }

    func testSelectionPaletteStillSupportsFullscreenUsage() {
        XCTAssertTrue(
            FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior.contains(.canJoinAllSpaces)
        )
        XCTAssertTrue(
            FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior.contains(.fullScreenAuxiliary)
        )
    }

    func testNotchIndicatorPolicyUsesScreenSaverLevelAboveStatusBarButBelowShielding() {
        let level = FloatingPanelSpacePolicy.notchIndicatorWindowLevel

        XCTAssertEqual(level, .screenSaver)
        XCTAssertGreaterThan(level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertLessThan(level.rawValue, Int(CGShieldingWindowLevel()))
    }

    func testFloatingIndicatorPolicyUsesFloatingLevelBelowStatusBar() {
        let level = FloatingPanelSpacePolicy.floatingIndicatorWindowLevel

        XCTAssertEqual(level, .floating)
        XCTAssertLessThan(level.rawValue, NSWindow.Level.statusBar.rawValue)
    }

    @MainActor
    func testIndicatorPolicyAppliesRequestedWindowLevelAndExcludesPanelFromScreenCapture() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        FloatingPanelSpacePolicy.applyIndicatorPolicy(
            to: panel,
            displayMode: .activeScreen,
            windowLevel: FloatingPanelSpacePolicy.floatingIndicatorWindowLevel
        )

        XCTAssertEqual(panel.level, FloatingPanelSpacePolicy.floatingIndicatorWindowLevel)
        XCTAssertEqual(panel.sharingType, .none)
    }
}
