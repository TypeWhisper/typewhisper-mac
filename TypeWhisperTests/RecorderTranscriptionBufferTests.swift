import XCTest
@testable import TypeWhisper

final class RecorderTranscriptionBufferTests: XCTestCase {
    func testRecentBufferReturnsTailForMicOnlySource() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic((0..<8).map(Float.init))

        let recent = buffer.recentBuffer(
            maxSampleCount: 3,
            micEnabled: true,
            systemAudioEnabled: false,
            mixer: { _, _, _ in
                XCTFail("mixer should not be used for mic-only buffers")
                return []
            }
        )

        XCTAssertEqual(recent, [5, 6, 7])
    }

    func testDeltaUsesMixedSampleCountAsNextOffset() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2])
        buffer.appendSystem([10, 20, 30, 40])

        let delta = buffer.delta(
            since: 3,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                range.map { index in
                    let micSample = index < micSamples.count ? micSamples[index] : 0
                    let systemSample = index < systemSamples.count ? systemSamples[index] : 0
                    return micSample + systemSample
                }
            }
        )

        XCTAssertEqual(delta.nextOffset, 4)
        XCTAssertEqual(delta.samples, [40])
    }

    func testMixedRecentBufferUsesTailRangeOnly() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2, 3, 4])
        buffer.appendSystem([10, 20, 30, 40])

        var capturedRange: Range<Int>?
        let recent = buffer.recentBuffer(
            maxSampleCount: 2,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                capturedRange = range
                return range.map { index in
                    micSamples[index] + systemSamples[index]
                }
            }
        )

        XCTAssertEqual(capturedRange, 2..<4)
        XCTAssertEqual(recent, [33, 44])
    }

    func testMixedDeltaReturnsOnlyRequestedSlice() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2, 3, 4])
        buffer.appendSystem([10, 20])

        let delta = buffer.delta(
            since: 1,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                range.map { index in
                    let micSample = index < micSamples.count ? micSamples[index] : 0
                    let systemSample = index < systemSamples.count ? systemSamples[index] : 0
                    return micSample + systemSample
                }
            }
        )

        XCTAssertEqual(delta.nextOffset, 4)
        XCTAssertEqual(delta.samples, [22, 3, 4])
    }
}
