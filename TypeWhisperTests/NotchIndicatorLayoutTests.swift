import XCTest
@testable import TypeWhisper

final class NotchIndicatorLayoutTests: XCTestCase {
    func testClosedHeightUsesScreenSafeAreaWhenAvailable() {
        XCTAssertEqual(NotchIndicatorLayout.closedHeight(hasNotch: true, safeAreaTopInset: 30), 30)
    }

    func testClosedHeightFallsBackToDefaultWhenNotchInsetUnavailable() {
        XCTAssertEqual(NotchIndicatorLayout.closedHeight(hasNotch: true, safeAreaTopInset: 0), 34)
    }

    func testClosedHeightUsesFallbackWithoutNotch() {
        XCTAssertEqual(NotchIndicatorLayout.closedHeight(hasNotch: false), 32)
    }

    func testClosedWidthUsesNotchWidthPlusExtensions() {
        XCTAssertEqual(NotchIndicatorLayout.closedWidth(hasNotch: true, notchWidth: 185), 305)
    }

    func testClosedWidthUsesFallbackWithoutNotch() {
        XCTAssertEqual(NotchIndicatorLayout.closedWidth(hasNotch: false, notchWidth: 0), 200)
    }

    func testRecordingClosedWidthKeepsBaselineWhenRecordingContentIsEmpty() {
        XCTAssertEqual(
            NotchIndicatorLayout.recordingClosedWidth(
                hasNotch: true,
                notchWidth: 185,
                leftContent: .none,
                rightContent: .none,
                recordingDuration: 3,
                activeRuleName: nil
            ),
            NotchIndicatorLayout.closedWidth(hasNotch: true, notchWidth: 185)
        )
    }

    func testRecordingClosedWidthExpandsForTimerAndWaveform() {
        let baseline = NotchIndicatorLayout.closedWidth(hasNotch: true, notchWidth: 185)
        let recordingWidth = NotchIndicatorLayout.recordingClosedWidth(
            hasNotch: true,
            notchWidth: 185,
            leftContent: .timer,
            rightContent: .waveform,
            recordingDuration: 83,
            activeRuleName: nil
        )

        XCTAssertGreaterThan(recordingWidth, baseline)
    }

    func testPreparingWidthReservesSpaceForStatusLabel() {
        let shortLabelWidth = NotchIndicatorLayout.preparingClosedWidth(
            hasNotch: false,
            notchWidth: 0,
            label: ""
        )
        let longLabelWidth = NotchIndicatorLayout.preparingClosedWidth(
            hasNotch: false,
            notchWidth: 0,
            label: "Mikrofon wird vorbereitet …"
        )

        XCTAssertGreaterThan(longLabelWidth, shortLabelWidth)
    }

    func testReservedTimerTextUsesTwoMinuteDigitsBelowOneHundredMinutes() {
        XCTAssertEqual(NotchIndicatorLayout.reservedTimerText(for: 3), "00:00")
    }

    func testReservedTimerTextKeepsTwoMinuteDigitsBelowOneHundredMinutesAtUpperBoundary() {
        XCTAssertEqual(NotchIndicatorLayout.reservedTimerText(for: 3599), "00:00")
    }

    func testReservedTimerTextUsesThreeMinuteDigitsAtOneHundredMinutes() {
        XCTAssertEqual(NotchIndicatorLayout.reservedTimerText(for: 6000), "000:00")
    }

    func testProfileChipWidthIsClampedToConfiguredMaximum() {
        XCTAssertEqual(
            NotchIndicatorLayout.recordingContentWidth(
                .profile,
                recordingDuration: 0,
                activeRuleName: "A very long workflow name that should definitely be truncated in the notch"
            ),
            NotchIndicatorLayout.profileChipMaxWidth
        )
    }

    func testContainerWidthClosedUsesClosedWidth() {
        XCTAssertEqual(NotchIndicatorLayout.containerWidth(closedWidth: 305, mode: .closed), 305)
    }

    func testContainerWidthProcessingAddsProcessingPadding() {
        XCTAssertEqual(NotchIndicatorLayout.containerWidth(closedWidth: 305, mode: .processing), 385)
    }

    func testContainerWidthFeedbackUsesMinimumFeedbackWidth() {
        XCTAssertEqual(NotchIndicatorLayout.containerWidth(closedWidth: 305, mode: .feedback), 340)
    }

    func testContainerWidthTranscriptUsesMinimumTranscriptWidth() {
        XCTAssertEqual(NotchIndicatorLayout.containerWidth(closedWidth: 305, mode: .transcript), 400)
    }

    func testModelContentWidensTheClosedNotchUpToTheChipLimit() {
        let width: (String) -> CGFloat = { title in
            NotchIndicatorLayout.recordingContentWidth(
                .model,
                recordingDuration: 0,
                activeRuleName: nil,
                modelTitle: title
            )
        }
        let short = width("Nova-3")
        let long = width(String(repeating: "Whisper Large v3 Turbo ", count: 4))
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(long, NotchIndicatorLayout.modelChipMaxWidth)

        let closed: (NotchIndicatorContent) -> CGFloat = { right in
            NotchIndicatorLayout.recordingClosedWidth(
                hasNotch: true,
                notchWidth: 180,
                leftContent: .timer,
                rightContent: right,
                recordingDuration: 0,
                activeRuleName: nil,
                modelTitle: "Parakeet TDT v3"
            )
        }
        XCTAssertGreaterThan(closed(.model), closed(.none))
    }

    func testRecorderShowsNoModelContent() {
        XCTAssertEqual(NotchIndicatorContent.model.shown(isRecorder: true), NotchIndicatorContent.none)
        XCTAssertEqual(NotchIndicatorContent.model.shown(isRecorder: false), NotchIndicatorContent.model)
        XCTAssertEqual(NotchIndicatorContent.timer.shown(isRecorder: true), NotchIndicatorContent.timer)
    }
}
