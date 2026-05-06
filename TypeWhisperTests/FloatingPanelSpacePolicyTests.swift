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
        XCTAssertFalse(primaryBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(primaryBehavior.contains(.fullScreenNone))
        XCTAssertEqual(primaryBehavior, builtInBehavior)
    }

    func testActiveScreenIndicatorPolicyDoesNotJoinForeignFullscreenSpaces() {
        XCTAssertFalse(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior(for: .activeScreen).contains(.fullScreenAuxiliary)
        )
        XCTAssertTrue(
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

    func testIndicatorPolicyUsesScreenSaverLevelAboveStatusBarButBelowShielding() {
        let level = FloatingPanelSpacePolicy.indicatorWindowLevel

        XCTAssertEqual(level, .screenSaver)
        XCTAssertGreaterThan(level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertLessThan(level.rawValue, Int(CGShieldingWindowLevel()))
    }
}
