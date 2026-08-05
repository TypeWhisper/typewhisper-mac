import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TypeWhisper

@MainActor
final class MeetingAutomationCountdownIndicatorTests: XCTestCase {
    func testCountdownTypographyUsesOneSharedFontSize() {
        XCTAssertEqual(CalendarMeetingCountdownTypography.fontSize, 11)
    }

    func testStartPresentationPublishesTitleStartAndDeadline() {
        let model = CalendarMeetingCountdownModel()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let deadline = startedAt.addingTimeInterval(5)

        model.presentStart(
            title: "Planning",
            startedAt: startedAt,
            deadline: deadline,
            onCancel: {}
        )

        XCTAssertEqual(
            model.presentation,
            CalendarMeetingCountdownPresentation(
                kind: .start(title: "Planning"),
                startedAt: startedAt,
                deadline: deadline
            )
        )
    }

    func testAutoStopPresentationPublishesStartAndDeadlineWithoutMeetingData() {
        let model = CalendarMeetingCountdownModel()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let deadline = startedAt.addingTimeInterval(15)

        model.presentAutoStop(startedAt: startedAt, deadline: deadline) {}

        XCTAssertEqual(
            model.presentation,
            CalendarMeetingCountdownPresentation(
                kind: .autoStop,
                startedAt: startedAt,
                deadline: deadline
            )
        )
    }

    func testCountdownRoundsUpAndClampsAtZero() {
        let deadline = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            CalendarMeetingCountdown.remainingSeconds(
                deadline: deadline,
                now: Date(timeIntervalSince1970: 98.01)
            ),
            2
        )
        XCTAssertEqual(
            CalendarMeetingCountdown.remainingSeconds(deadline: deadline, now: deadline),
            0
        )
        XCTAssertEqual(
            CalendarMeetingCountdown.remainingSeconds(
                deadline: deadline,
                now: deadline.addingTimeInterval(10)
            ),
            0
        )
    }

    func testCountdownFractionIsClamped() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let deadline = startedAt.addingTimeInterval(20)

        XCTAssertEqual(
            CalendarMeetingCountdown.remainingFraction(
                startedAt: startedAt,
                deadline: deadline,
                now: startedAt.addingTimeInterval(10)
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CalendarMeetingCountdown.remainingFraction(
                startedAt: startedAt,
                deadline: deadline,
                now: startedAt.addingTimeInterval(-10)
            ),
            1
        )
        XCTAssertEqual(
            CalendarMeetingCountdown.remainingFraction(
                startedAt: startedAt,
                deadline: deadline,
                now: deadline.addingTimeInterval(10)
            ),
            0
        )
    }

    func testCountdownCadenceUsesThirtyHertzAndReducedMotionUsesOneSecond() {
        XCTAssertEqual(
            CalendarMeetingCountdown.minimumInterval(reduceMotion: false),
            1.0 / 30.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            CalendarMeetingCountdown.minimumInterval(reduceMotion: true),
            1,
            accuracy: 0.000_001
        )
    }

    func testStartCancelRunsAtMostOnceAndRemovesKeyboardAction() {
        let hotkeyService = HotkeyService()
        let model = CalendarMeetingCountdownModel(hotkeyService: hotkeyService)
        var cancellationCount = 0
        model.presentStart(
            title: "Planning",
            startedAt: .now,
            deadline: .now.addingTimeInterval(5)
        ) {
            cancellationCount += 1
        }

        XCTAssertTrue(hotkeyService.hasMeetingCountdownActionForTesting())
        model.cancelStart()
        model.cancelStart()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(model.presentation)
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())
    }

    func testIndicatorButtonMarksBackgroundInteractionBeforeRunningAction() throws {
        var events: [String] = []
        let model = CalendarMeetingCountdownModel(onButtonAction: {
            events.append("background")
        })
        model.presentAutoStop(
            startedAt: .now,
            deadline: .now.addingTimeInterval(15)
        ) {
            events.append("continue")
        }
        let presentation = try XCTUnwrap(model.presentation)

        model.action(for: presentation)()

        XCTAssertEqual(events, ["background", "continue"])
        XCTAssertNil(model.presentation)
    }

    func testKeyboardShortcutCancelsStartAndIsNotRegisteredForAutoStop() {
        let hotkeyService = HotkeyService()
        let model = CalendarMeetingCountdownModel(hotkeyService: hotkeyService)
        var cancellationCount = 0

        model.presentStart(
            title: "Planning",
            startedAt: .now,
            deadline: .now.addingTimeInterval(5)
        ) {
            cancellationCount += 1
        }
        hotkeyService.performMeetingCountdownActionForTesting()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())

        model.presentAutoStop(
            startedAt: .now,
            deadline: .now.addingTimeInterval(15)
        ) {}
        XCTAssertFalse(hotkeyService.hasMeetingCountdownActionForTesting())
    }

    func testTypedDismissCannotRemoveOtherCountdownKind() {
        let model = CalendarMeetingCountdownModel()
        let startedAt = Date(timeIntervalSince1970: 100)

        model.presentAutoStop(
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(15)
        ) {}
        let autoStop = model.presentation
        model.dismissStart()
        XCTAssertEqual(model.presentation, autoStop)

        model.dismissAutoStop()
        XCTAssertNil(model.presentation)

        model.presentStart(
            title: "Planning",
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(5)
        ) {}
        let start = model.presentation
        model.dismissAutoStop()
        XCTAssertEqual(model.presentation, start)
    }

    func testReplacedPresentationRejectsLateAction() throws {
        let model = CalendarMeetingCountdownModel()
        var firstActionCount = 0
        var secondActionCount = 0
        let firstStart = Date(timeIntervalSince1970: 100)
        model.presentStart(
            title: "First",
            startedAt: firstStart,
            deadline: firstStart.addingTimeInterval(5)
        ) {
            firstActionCount += 1
        }
        let firstPresentation = try XCTUnwrap(model.presentation)
        let delayedFirstAction = model.action(for: firstPresentation)

        let secondStart = Date(timeIntervalSince1970: 200)
        model.presentAutoStop(
            startedAt: secondStart,
            deadline: secondStart.addingTimeInterval(15)
        ) {
            secondActionCount += 1
        }
        let secondPresentation = try XCTUnwrap(model.presentation)
        let currentAction = model.action(for: secondPresentation)

        delayedFirstAction()
        XCTAssertEqual(firstActionCount, 0)
        XCTAssertEqual(secondActionCount, 0)
        XCTAssertEqual(model.presentation, secondPresentation)

        currentAction()
        XCTAssertEqual(firstActionCount, 0)
        XCTAssertEqual(secondActionCount, 1)
        XCTAssertNil(model.presentation)
    }

    func testQueuedKeyboardShortcutCannotInvokeReplacementCountdown() async throws {
        let hotkeyService = HotkeyService()
        let model = CalendarMeetingCountdownModel(hotkeyService: hotkeyService)
        var firstCancellationCount = 0
        var replacementCancellationCount = 0

        model.presentStart(
            title: "First",
            startedAt: .now,
            deadline: .now.addingTimeInterval(5)
        ) {
            firstCancellationCount += 1
        }
        let queuedAction = try XCTUnwrap(
            hotkeyService.queueMeetingCountdownActionForTesting()
        )

        model.presentStart(
            title: "Replacement",
            startedAt: .now,
            deadline: .now.addingTimeInterval(5)
        ) {
            replacementCancellationCount += 1
        }
        await queuedAction.value

        XCTAssertEqual(firstCancellationCount, 0)
        XCTAssertEqual(replacementCancellationCount, 0)

        hotkeyService.performMeetingCountdownActionForTesting()
        XCTAssertEqual(replacementCancellationCount, 1)
    }

    func testPresentingCountdownDoesNotCreateAdditionalWindow() {
        let knownWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let model = CalendarMeetingCountdownModel()

        model.presentStart(
            title: "Planning",
            startedAt: .now,
            deadline: .now.addingTimeInterval(5)
        ) {}

        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), knownWindows)
    }

    func testAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.startIndicator,
            "calendarMeeting.startCountdown.indicator"
        )
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.startCountdown,
            "calendarMeeting.startCountdown.countdown"
        )
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.cancelStart,
            "calendarMeeting.startCountdown.cancel"
        )
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.autoStopIndicator,
            "calendarMeeting.autoStopIndicator"
        )
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.autoStopCountdown,
            "calendarMeeting.autoStopIndicator.countdown"
        )
        XCTAssertEqual(
            CalendarMeetingCountdownIndicatorAccessibility.continueRecording,
            "calendarMeeting.autoStopIndicator.continue"
        )
    }

    func testCountdownOverridesNeverVisibilityAndFullscreenSuppressionOnlyWhilePresented() {
        XCTAssertTrue(CalendarMeetingCountdownIndicatorPolicy.shouldShow(
            normalVisibilityAllowsPresentation: false,
            countdownPresented: true
        ))
        XCTAssertFalse(CalendarMeetingCountdownIndicatorPolicy.shouldShow(
            normalVisibilityAllowsPresentation: false,
            countdownPresented: false
        ))
        XCTAssertFalse(CalendarMeetingCountdownIndicatorPolicy.shouldSuppressForFullscreen(
            normallySuppressed: true,
            countdownPresented: true
        ))
        XCTAssertTrue(CalendarMeetingCountdownIndicatorPolicy.shouldSuppressForFullscreen(
            normallySuppressed: true,
            countdownPresented: false
        ))
    }

    func testOverlayStartUsesStandaloneHeightWhileAutoStopKeepsRecorderStatusHeight() {
        let startSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .overlay,
            isFeedbackInteractive: true,
            countdownKind: .start(title: "Planning")
        )
        let autoStopSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .overlay,
            isFeedbackInteractive: true,
            countdownKind: .autoStop
        )

        XCTAssertEqual(startSize.height, IndicatorFeedbackPanelLayout.feedbackBodyHeight)
        XCTAssertEqual(
            autoStopSize.height,
            IndicatorFeedbackPanelLayout.overlayStatusHeight
                + IndicatorFeedbackPanelLayout.feedbackBodyHeight
        )
    }

    func testPanelsRemainNonactivatingAndAcceptFirstMouse() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("Indicator panel tests require an available screen")
        }
        let model = CalendarMeetingCountdownModel()
        let resolver = IndicatorScreenResolver(
            focusedElementPositionProvider: { nil },
            focusedWindowFrameProvider: { nil },
            frontmostApplicationProvider: { nil },
            mouseLocationProvider: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) },
            screensProvider: { [screen] },
            mainScreenProvider: { screen },
            windowFrameProvider: { _ in nil }
        )
        let notch = NotchIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            countdownModel: model,
            content: { _ in EmptyView() }
        )
        let overlay = OverlayIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            countdownModel: model,
            content: { EmptyView() }
        )
        let minimal = MinimalIndicatorPanel(
            screenResolver: resolver,
            displayModeProvider: { .activeScreen },
            overlayPositionProvider: { .top },
            countdownModel: model,
            content: { EmptyView() }
        )
        let panels: [NSPanel] = [notch, overlay, minimal]

        for panel in panels {
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.contentView?.acceptsFirstMouse(for: nil) == true)
        }
    }
}
