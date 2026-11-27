import XCTest
@testable import TypeWhisper

/// The permission guide sits beside the System Settings window so it never covers the
/// switch the user has to turn on.
final class PermissionGuidePlacementTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
    private let panelSize = NSSize(width: 300, height: 180)

    func testPlacesGuideRightOfSettingsLevelWithTheList() {
        let settings = NSRect(x: 400, y: 200, width: 700, height: 600)

        let origin = PermissionGuidePlacement.origin(panelSize: panelSize, settingsFrame: settings, visibleFrame: screen)

        XCTAssertEqual(origin.x, settings.maxX + PermissionGuidePlacement.gap)
        XCTAssertEqual(origin.y + panelSize.height, settings.maxY - PermissionGuidePlacement.toolbarHeight)
    }

    func testFallsBackToTheLeftWhenTheRightEdgeIsTooClose() {
        let settings = NSRect(x: 1000, y: 200, width: 800, height: 600)

        let origin = PermissionGuidePlacement.origin(panelSize: panelSize, settingsFrame: settings, visibleFrame: screen)

        XCTAssertEqual(origin.x + panelSize.width, settings.minX - PermissionGuidePlacement.gap)
    }

    func testOverlapsBottomRightCornerOfAWindowThatFillsTheScreen() {
        let settings = screen

        let origin = PermissionGuidePlacement.origin(panelSize: panelSize, settingsFrame: settings, visibleFrame: screen)
        let guide = NSRect(origin: origin, size: panelSize)

        XCTAssertTrue(screen.contains(guide))
        XCTAssertEqual(guide.maxX, settings.maxX - PermissionGuidePlacement.margin)
        XCTAssertEqual(guide.minY, settings.minY + PermissionGuidePlacement.margin)
    }

    func testConvertsWindowBoundsFromTopLeftScreenCoordinates() {
        let bounds = CGRect(x: 100, y: 50, width: 700, height: 600)

        let frame = SystemSettingsWindowLocator.cocoaFrame(fromWindowBounds: bounds, primaryScreenHeight: 1080)

        XCTAssertEqual(frame, NSRect(x: 100, y: 430, width: 700, height: 600))
    }
}
