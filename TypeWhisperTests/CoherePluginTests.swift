import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class CoherePluginTests: XCTestCase {
    func testUploadPutsHalfASecondOfSilenceBeforeAndAfterTheRecording() {
        let samples: [Float] = [0.5, -0.5, 0.25]
        let silence = [Float](repeating: 0, count: 8_000)

        let wav = CoherePlugin.paddedWavData(samples)

        XCTAssertEqual(wav.count, 44 + 2 * (8_000 + samples.count + 8_000))
        XCTAssertEqual(wav, PluginWavEncoder.encode(silence + samples + silence, sampleRate: 16_000))
    }
}
