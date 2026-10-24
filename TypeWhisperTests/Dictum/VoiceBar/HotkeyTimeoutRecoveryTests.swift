import AppKit
import XCTest
@testable import TypeWhisper

final class HotkeyTimeoutRecoveryTests: XCTestCase {
    @MainActor
    func testTimedOutFnReleaseStopsHeldRecordingOnceMainThreadRecovers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        defer { service.suspendMonitoring() }
        for slot in HotkeySlotType.allCases {
            service.setHotkeysForTesting([], for: slot)
        }
        service.setHotkeyForTesting(
            UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true),
            for: .hybrid
        )
        service.modifierFlagsStateProvider = { [] }
        var starts = 0
        var stops = 0
        service.onDictationStart = { _ in starts += 1 }
        service.onDictationStop = { stops += 1 }
        let press = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        press.type = .flagsChanged
        press.flags = .maskSecondaryFn
        XCTAssertTrue(service.processEventForTesting(try XCTUnwrap(NSEvent(cgEvent: press)), source: .monitor))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        Thread.sleep(forTimeInterval: 0.36)
        nonisolated(unsafe) let release = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false)
        )
        release.type = .flagsChanged
        release.flags = []
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertFalse(service.decideEventTapEventForTesting(release))
            XCTAssertFalse(service.decideEventTapEventForTesting(release))
            released.signal()
        }
        XCTAssertEqual(released.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stops, 0)

        let deadline = Date().addingTimeInterval(1)
        while stops == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(stops, 1)
        XCTAssertNil(service.currentMode)
        service.processGlobalEventForTesting(try XCTUnwrap(NSEvent(cgEvent: release)))
        service.recoverReleasedActiveHotkeyAfterEventTapDisableForTesting()
        XCTAssertEqual(stops, 1)
    }
}
