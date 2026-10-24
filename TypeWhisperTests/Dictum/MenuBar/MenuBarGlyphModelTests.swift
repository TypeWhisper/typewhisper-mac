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

    func testAudioLevelChangesDuringRecordingPublishNothing() async {
        let dictation = DictationViewModel.shared
        defer { dictation.state = .idle; dictation.audioLevel = 0; dictation.recordingDuration = 0 }
        let glyph = makeGlyph()
        dictation.state = .recording
        await waitUntil { glyph.appearance == .recording }
        XCTAssertEqual(glyph.appearance, .recording)

        var publications = 0
        let subscription = glyph.objectWillChange.sink { publications += 1 }
        for step in 0..<200 {
            dictation.audioLevel = Float(step % 10) / 10
            dictation.recordingDuration += 0.05
        }
        try? await Task.sleep(for: .milliseconds(150))
        subscription.cancel()

        XCTAssertEqual(publications, 0)
    }

    func testPolishingAlternatesBrightAndDimmedImages() async {
        let dictation = DictationViewModel.shared
        defer { dictation.state = .idle }
        let glyph = makeGlyph(pulseInterval: 0.02)
        dictation.state = .processing
        await waitUntil { glyph.appearance == .polishing }

        var sawBright = false
        var sawDimmed = false
        for _ in 0..<40 {
            let peak = peakAlpha(of: glyph.currentImage)
            if peak > 0.9 { sawBright = true }
            if peak > 0, peak < 0.5 { sawDimmed = true }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(sawBright)
        XCTAssertTrue(sawDimmed)
    }

    func testPulseStopsWhenPolishingEnds() async {
        let dictation = DictationViewModel.shared
        defer { dictation.state = .idle }
        let glyph = makeGlyph(pulseInterval: 0.02)
        dictation.state = .processing
        await waitUntil { glyph.appearance == .polishing }
        dictation.state = .idle
        await waitUntil { glyph.appearance == .idle }
        XCTAssertFalse(glyph.pulseOn)

        var publications = 0
        let subscription = glyph.objectWillChange.sink { publications += 1 }
        try? await Task.sleep(for: .milliseconds(200))
        subscription.cancel()

        XCTAssertEqual(publications, 0)
    }

    func testFirstStatusChangeDoesNotWaitForAModelChange() async {
        let dictation = DictationViewModel.shared
        defer { dictation.state = .idle }
        let glyph = makeGlyph()
        XCTAssertEqual(glyph.appearance, .idle)

        dictation.state = .recording
        await waitUntil { glyph.appearance == .recording }

        XCTAssertEqual(glyph.appearance, .recording)
    }

    func testAccessibilityTrustIsRefreshedPeriodically() async {
        var trusted = true
        let glyph = MenuBarGlyphModel(
            accessibilityChecker: { trusted },
            isModelReady: { true },
            accessibilityRefreshInterval: 0.02
        )
        XCTAssertEqual(glyph.appearance, .idle)

        trusted = false
        await waitUntil { glyph.appearance == .attention }

        XCTAssertEqual(glyph.appearance, .attention)
    }

    func testPreRenderedImagesFollowAppearanceTemplateRules() {
        XCTAssertTrue(MenuBarGlyphImages.cachedImage(for: .idle).isTemplate)
        XCTAssertFalse(MenuBarGlyphImages.cachedImage(for: .recording).isTemplate)
        XCTAssertFalse(MenuBarGlyphImages.cachedImage(for: .attention).isTemplate)
        // 润色脉冲靠整图的透明度差异交替，仍按模板渲染跟随菜单栏配色。
        XCTAssertTrue(MenuBarGlyphImages.cachedImage(for: .polishing, isPulseOn: true).isTemplate)
        XCTAssertTrue(MenuBarGlyphImages.cachedImage(for: .polishing, isPulseOn: false).isTemplate)
    }

    func testPulseIntervalIsAtLeastAQuarterSecond() {
        XCTAssertGreaterThanOrEqual(MenuBarGlyphImages.pulseInterval, 0.25)
    }

    private func makeGlyph(pulseInterval: TimeInterval = MenuBarGlyphImages.pulseInterval) -> MenuBarGlyphModel {
        MenuBarGlyphModel(accessibilityChecker: { true }, isModelReady: { true }, pulseInterval: pulseInterval)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func peakAlpha(of image: NSImage) -> CGFloat {
        let size = 36
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var peak: CGFloat = 0
        for x in 0..<size {
            for y in 0..<size {
                peak = max(peak, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return peak
    }
}
