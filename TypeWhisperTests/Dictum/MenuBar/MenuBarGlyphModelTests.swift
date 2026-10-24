import XCTest
@testable import TypeWhisper

@MainActor
final class MenuBarGlyphModelTests: XCTestCase {
    func testResolveShowsAttentionWithoutAccessibility() {
        let status = MenuBarGlyphModel.resolve(
            dictationState: .idle,
            isModelReady: true,
            accessibility: false,
            downloadProgress: nil
        )
        XCTAssertEqual(status.appearance, .attention)
    }

    func testResolveShowsAttentionWithoutReadyModel() {
        let status = MenuBarGlyphModel.resolve(
            dictationState: .idle,
            isModelReady: false,
            accessibility: true,
            downloadProgress: nil
        )
        XCTAssertEqual(status.appearance, .attention)
    }

    func testResolveKeepsDownloadProgressWhileIdle() {
        let status = MenuBarGlyphModel.resolve(
            dictationState: .idle,
            isModelReady: true,
            accessibility: true,
            downloadProgress: 0.4
        )
        XCTAssertEqual(status.appearance, .idle)
        XCTAssertEqual(status.downloadProgress, 0.4)
    }

    func testResolveShowsRecordingRegardlessOfDownloadProgress() {
        let status = MenuBarGlyphModel.resolve(
            dictationState: .recording,
            isModelReady: true,
            accessibility: true,
            downloadProgress: 0.4
        )
        XCTAssertEqual(status.appearance, .recording)
        XCTAssertNil(status.downloadProgress)
    }

    func testResolveShowsPolishingWhileProcessing() {
        let status = MenuBarGlyphModel.resolve(
            dictationState: .processing,
            isModelReady: true,
            accessibility: true,
            downloadProgress: nil
        )
        XCTAssertEqual(status.appearance, .polishing)
    }

    func testAudioLevelChangeDoesNotChangeResolvedStatus() {
        // 录音电平不属于任何状态输入；去重后它不得触发状态项重绘。
        let before = MenuBarGlyphModel.resolve(
            dictationState: .recording,
            isModelReady: true,
            accessibility: true,
            downloadProgress: nil
        )
        let after = MenuBarGlyphModel.resolve(
            dictationState: .recording,
            isModelReady: true,
            accessibility: true,
            downloadProgress: nil
        )
        XCTAssertEqual(before, after)
    }

    func testPreRenderedImagesAreStablePerAppearance() {
        let idle = MenuBarGlyphImages.cachedImage(for: .idle)
        XCTAssertTrue(idle.isTemplate)
        let recording = MenuBarGlyphImages.cachedImage(for: .recording)
        XCTAssertFalse(recording.isTemplate)
        XCTAssertFalse(MenuBarGlyphImages.cachedImage(for: .attention).isTemplate)
        // 润色脉冲靠预渲染图的透明度差异交替，仍按模板渲染跟随菜单栏配色。
        XCTAssertTrue(MenuBarGlyphImages.polishingImage(isPulseOn: true).isTemplate)
        XCTAssertTrue(MenuBarGlyphImages.polishingImage(isPulseOn: false).isTemplate)
    }

    func testPulseIntervalIsAtLeastAQuarterSecond() {
        XCTAssertGreaterThanOrEqual(MenuBarGlyphImages.pulseInterval, 0.25)
    }
}
