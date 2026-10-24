import XCTest
@testable import TypeWhisper

final class HybridHotkeyTimingTests: XCTestCase {
    func testReleaseAt034SecondsKeepsToggleRecording() {
        XCTAssertTrue(HotkeyService.isHybridTap(heldFor: 0.34))
    }

    func testReleaseAtOrAfter035SecondsStopsPushToTalkRecording() {
        XCTAssertFalse(HotkeyService.isHybridTap(heldFor: 0.35))
        XCTAssertFalse(HotkeyService.isHybridTap(heldFor: 0.36))
        XCTAssertFalse(HotkeyService.isHybridTap(heldFor: 1.0))
    }
}
