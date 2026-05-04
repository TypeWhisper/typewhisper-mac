import AppKit
import XCTest
@testable import TypeWhisper

final class FloatingPanelSpacePolicyTests: XCTestCase {
    func testIndicatorPolicyTargetsOnlyTheActiveNormalSpace() {
        let behavior = FloatingPanelSpacePolicy.indicatorCollectionBehavior

        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
    }

    func testIndicatorPolicyDoesNotJoinForeignFullscreenSpaces() {
        XCTAssertFalse(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior.contains(.fullScreenAuxiliary)
        )
        XCTAssertTrue(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior.contains(.fullScreenNone)
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
