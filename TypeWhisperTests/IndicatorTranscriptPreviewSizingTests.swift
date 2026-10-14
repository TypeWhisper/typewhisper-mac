import XCTest
@testable import TypeWhisper

final class IndicatorTranscriptPreviewSizingTests: XCTestCase {
    func testTranscriptAreaFollowsItsTextUpToTheMaximum() {
        // One line of 13 pt text plus padding; a single sentence no longer opens the full box.
        XCTAssertEqual(
            IndicatorExpandableText.visibleHeight(contentHeight: 45, expanded: true, maximum: 100, fontSize: 13),
            45
        )
        XCTAssertEqual(
            IndicatorExpandableText.visibleHeight(contentHeight: 180, expanded: true, maximum: 100, fontSize: 13),
            100
        )
    }

    func testTranscriptAreaKeepsOneLineBeforeTextArrives() {
        let singleLine = (13 * 1.25).rounded(.up) + 2 * IndicatorExpandableText.verticalPadding
        XCTAssertEqual(
            IndicatorExpandableText.visibleHeight(contentHeight: 0, expanded: true, maximum: 100, fontSize: 13),
            singleLine
        )
    }

    func testTranscriptAreaCollapsesWhenNotExpanded() {
        XCTAssertEqual(
            IndicatorExpandableText.visibleHeight(contentHeight: 60, expanded: false, maximum: 100, fontSize: 13),
            0
        )
        XCTAssertEqual(
            IndicatorExpandableText.visibleHeight(contentHeight: 60, expanded: true, maximum: 0, fontSize: 12),
            0
        )
    }

    func testNotchExpandedHeightScalesWithFontSize() {
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewExpandedHeight(for: .notch, offset: 0), 80)
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewExpandedHeight(for: .notch, offset: 8), 134)
    }

    func testOverlayExpandedHeightScalesWithFontSize() {
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewExpandedHeight(for: .overlay, offset: 0), 100)
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewExpandedHeight(for: .overlay, offset: 8), 162)
    }

    func testMaximumOffsetKeepsStyleRelativeFontSizes() {
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .notch, offset: 8), 20)
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .overlay, offset: 8), 21)
    }

    func testSameOffsetProducesStyleSpecificFontSizes() {
        let offset = 4

        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .notch, offset: offset), 16)
        XCTAssertEqual(DictationViewModel.indicatorTranscriptPreviewFontSize(for: .overlay, offset: offset), 17)
    }

    func testOverlayTranscriptPreviewExpandsForRecordingPartialText() {
        let state = OverlayTranscriptPreviewState(
            isRecording: true,
            previewEnabled: true,
            isRecorder: false,
            externalStreamingDisplayCount: 0,
            partialText: "Hello",
            textExpanded: false
        )

        XCTAssertTrue(state.hasTranscriptSection)
        XCTAssertTrue(state.shouldExpandForCurrentText)
    }

    func testOverlayTranscriptPreviewCollapsesWhenDisabled() {
        let state = OverlayTranscriptPreviewState(
            isRecording: true,
            previewEnabled: false,
            isRecorder: false,
            externalStreamingDisplayCount: 0,
            partialText: "Hello",
            textExpanded: false
        )

        XCTAssertFalse(state.showTranscriptPreview)
        XCTAssertFalse(state.hasTranscriptSection)
        XCTAssertFalse(state.shouldExpandForCurrentText)
    }

    func testOverlayTranscriptPreviewSuppressesWhenExternalStreamingDisplayIsActive() {
        let state = OverlayTranscriptPreviewState(
            isRecording: true,
            previewEnabled: true,
            isRecorder: false,
            externalStreamingDisplayCount: 1,
            partialText: "Hello",
            textExpanded: false
        )

        XCTAssertTrue(state.suppressStreamingText)
        XCTAssertFalse(state.showTranscriptPreview)
        XCTAssertFalse(state.hasTranscriptSection)
        XCTAssertFalse(state.shouldExpandForCurrentText)
    }
}
