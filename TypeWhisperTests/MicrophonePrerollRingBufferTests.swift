import XCTest
@testable import TypeWhisper

final class MicrophonePrerollRingBufferTests: XCTestCase {
    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map { Float($0) }
    }

    func testStartsEmpty() {
        let ring = MicrophonePrerollRingBuffer(capacity: 8)

        XCTAssertEqual(ring.count, 0)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.drain(), [])
    }

    func testCapacityFromDurationAndSampleRate() {
        let ring = MicrophonePrerollRingBuffer(duration: 0.5, sampleRate: 16_000)

        XCTAssertEqual(ring.capacity, 8_000)
    }

    func testDrainReturnsSamplesOldestFirstAndEmptiesTheRing() {
        let ring = MicrophonePrerollRingBuffer(capacity: 8)
        ring.append(ramp(0..<3))
        ring.append(ramp(3..<5))

        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.drain(), ramp(0..<5))
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.drain(), [])
    }

    func testFillingExactlyToCapacityKeepsEverything() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append(ramp(0..<4))

        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.drain(), ramp(0..<4))
    }

    func testWrapAroundDropsTheOldestSamples() {
        let ring = MicrophonePrerollRingBuffer(capacity: 5)
        ring.append(ramp(0..<4))
        ring.append(ramp(4..<7))

        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.drain(), ramp(2..<7))
    }

    func testRepeatedWrapsKeepTheNewestWindowInOrder() {
        let ring = MicrophonePrerollRingBuffer(capacity: 6)
        var next = 0
        for chunk in [1, 4, 2, 5, 3, 6, 1, 2] {
            ring.append(ramp(next..<(next + chunk)))
            next += chunk
        }

        XCTAssertEqual(ring.drain(), ramp((next - 6)..<next))
    }

    func testSingleAppendLargerThanCapacityKeepsOnlyTheNewestSamples() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append(ramp(0..<2))
        ring.append(ramp(10..<20))

        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.drain(), ramp(16..<20))
    }

    func testRingIsReusableAfterDrain() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append(ramp(0..<6))
        _ = ring.drain()
        ring.append(ramp(100..<103))

        XCTAssertEqual(ring.drain(), ramp(100..<103))
    }

    func testSnapshotDoesNotConsumeTheContents() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append(ramp(0..<6))

        XCTAssertEqual(ring.snapshot(), ramp(2..<6))
        XCTAssertEqual(ring.count, 4)
        XCTAssertEqual(ring.drain(), ramp(2..<6))
    }

    func testResetDropsContents() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append(ramp(0..<3))
        ring.reset()

        XCTAssertEqual(ring.count, 0)
        ring.append(ramp(7..<9))
        XCTAssertEqual(ring.drain(), ramp(7..<9))
    }

    func testEmptyAppendIsIgnored() {
        let ring = MicrophonePrerollRingBuffer(capacity: 4)
        ring.append([])

        XCTAssertEqual(ring.count, 0)
    }

    func testConcurrentAppendsNeverExceedCapacityOrCorruptTheRing() {
        let ring = MicrophonePrerollRingBuffer(capacity: 1_000)
        let writerCount = 4
        let chunksPerWriter = 500
        let chunkSize = 16
        let queue = DispatchQueue(label: "ring-test", attributes: .concurrent)
        let group = DispatchGroup()

        for writer in 0..<writerCount {
            group.enter()
            queue.async {
                let chunk = [Float](repeating: Float(writer + 1), count: chunkSize)
                for _ in 0..<chunksPerWriter {
                    ring.append(chunk)
                }
                group.leave()
            }
        }
        group.enter()
        queue.async {
            for _ in 0..<200 {
                XCTAssertLessThanOrEqual(ring.snapshot().count, 1_000)
            }
            group.leave()
        }
        group.wait()

        let samples = ring.drain()
        XCTAssertEqual(samples.count, 1_000)
        XCTAssertTrue(samples.allSatisfy { $0 >= 1 && $0 <= Float(writerCount) })
    }
}
