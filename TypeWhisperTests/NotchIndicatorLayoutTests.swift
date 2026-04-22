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
}
