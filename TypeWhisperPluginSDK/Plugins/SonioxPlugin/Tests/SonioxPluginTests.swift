import XCTest
import TypeWhisperPluginSDK
@testable import SonioxPlugin

final class SonioxPluginTests: XCTestCase {
    func testSourceProgressUsesFinalOriginalTokenTiming() {
        let progress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1500],
                ["text": "hola", "is_final": true, "end_ms": 9000, "translation_status": "translation"],
                ["text": "draft", "is_final": false, "end_ms": 8000],
            ],
            totalDuration: 10
        )

        XCTAssertEqual(progress?.processedDuration, 1.5)
        XCTAssertEqual(progress?.totalDuration, 10)
        XCTAssertEqual(progress?.fractionCompleted, 0.15)
    }

    func testSourceProgressRequiresTimedFinalOriginalTokens() {
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "translated", "is_final": true, "end_ms": 2000, "translation_status": "translation"],
                ["text": "untimed", "is_final": true],
            ],
            totalDuration: 10
        ))

        let clampedProgress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "late", "is_final": true, "end_ms": "12000"],
            ],
            totalDuration: 10
        )
        XCTAssertEqual(clampedProgress?.processedDuration, 10)
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1000],
            ],
            totalDuration: 0
        ))
    }
}
