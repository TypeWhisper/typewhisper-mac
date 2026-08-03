import AppKit
import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingAutomationCountdownPanelTests: XCTestCase {
    func testPresentationModelsExposeExactDeadlinesAndAccessibilityIDs() {
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(MeetingAutomationCountdownPresentation.start(
            title: "Planning",
            deadline: deadline
        ).deadline, deadline)
        XCTAssertEqual(MeetingAutomationCountdownPresentation.stop(deadline: deadline).deadline, deadline)
        XCTAssertEqual(
            MeetingAutomationCountdownAccessibility.cancelStart,
            "calendarMeeting.startCountdown.cancel"
        )
        XCTAssertEqual(
            MeetingAutomationCountdownAccessibility.continueRecording,
            "calendarMeeting.stopCountdown.continue"
        )
    }

    func testPanelIsNonActivatingAndNeverBecomesMainOrKey() {
        let knownWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let presenter = MeetingAutomationCountdownPanelController()
        presenter.showStart(
            title: "Planning",
            deadline: Date().addingTimeInterval(5),
            onCancel: {}
        )
        defer { presenter.dismiss() }

        let panel = NSApp.windows.first {
            !knownWindows.contains(ObjectIdentifier($0)) && $0 is NSPanel
        }
        XCTAssertNotNil(panel)
        XCTAssertTrue(panel?.styleMask.contains(.nonactivatingPanel) == true)
        XCTAssertFalse(panel?.canBecomeKey ?? true)
        XCTAssertFalse(panel?.canBecomeMain ?? true)
        XCTAssertTrue(panel?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        XCTAssertTrue(panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true)

        presenter.dismiss()
        XCTAssertFalse(panel?.isVisible ?? true)
    }

    func testKeyboardShortcutInvokesBothActionsAndIsRemovedWithCountdown() {
        let hotkeyService = HotkeyService()
        let presenter = MeetingAutomationCountdownPanelController(hotkeyService: hotkeyService)
        var startCancellations = 0
        var stopVetos = 0
        defer { presenter.dismiss() }

        presenter.showStart(
            title: "Planning",
            deadline: Date().addingTimeInterval(5),
            onCancel: { startCancellations += 1 }
        )
        XCTAssertTrue(hotkeyService.hasMeetingCountdownActionForTesting())
        hotkeyService.performMeetingCountdownActionForTesting()
        XCTAssertEqual(startCancellations, 1)
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())

        presenter.showStop(
            deadline: Date().addingTimeInterval(15),
            onContinue: { stopVetos += 1 }
        )
        XCTAssertTrue(hotkeyService.hasMeetingCountdownActionForTesting())
        hotkeyService.performMeetingCountdownActionForTesting()
        XCTAssertEqual(stopVetos, 1)
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())

        presenter.showStart(
            title: "Planning",
            deadline: Date().addingTimeInterval(5),
            onCancel: { startCancellations += 1 }
        )
        presenter.dismiss()
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())
        XCTAssertEqual(startCancellations, 1)
    }
}
