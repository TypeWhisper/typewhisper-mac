import AppKit
import XCTest
@testable import TypeWhisper

final class FloatingPanelSpacePolicyTests: XCTestCase {
    func testIndicatorPolicyKeepsNormalDesktopSpaceBehavior() {
        let behavior = FloatingPanelSpacePolicy.indicatorCollectionBehavior

        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }

    func testIndicatorPolicyDoesNotJoinForeignFullscreenSpaces() {
        XCTAssertFalse(
            FloatingPanelSpacePolicy.indicatorCollectionBehavior.contains(.fullScreenAuxiliary)
        )
    }

    func testSelectionPaletteStillSupportsFullscreenUsage() {
        XCTAssertTrue(
            FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior.contains(.fullScreenAuxiliary)
        )
    }

    func testIndicatorPolicyKeepsShieldingWindowLevel() {
        XCTAssertEqual(
            FloatingPanelSpacePolicy.indicatorWindowLevel,
            NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        )
    }
}
