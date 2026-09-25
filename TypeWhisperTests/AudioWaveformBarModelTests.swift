import XCTest
@testable import TypeWhisper

final class AudioWaveformBarModelTests: XCTestCase {
    private let frame: TimeInterval = 1.0 / 60.0

    private func run(_ model: inout AudioWaveformBarModel, from start: TimeInterval, seconds: TimeInterval, level: Float, setup: Bool = false) -> [CGFloat] {
        var heights: [CGFloat] = []
        var now = start
        while now < start + seconds {
            heights = model.advance(to: now, level: level, setup: setup)
            now += frame
        }
        return heights
    }

    func testBarsStayFlatWithoutSignal() {
        var model = AudioWaveformBarModel(barCount: 5)

        let heights = run(&model, from: 10, seconds: 1, level: 0)

        XCTAssertEqual(heights.count, 5)
        XCTAssertTrue(heights.allSatisfy { $0 == 0 })
    }

    func testBarsRiseWithSignalAndStayInRange() {
        var model = AudioWaveformBarModel(barCount: 5)

        let heights = run(&model, from: 10, seconds: 1, level: 1)

        XCTAssertTrue(heights.allSatisfy { $0 > 0.3 && $0 <= 1 }, "\(heights)")
    }

    func testCenterBarsReachHigherThanOuterBars() {
        var model = AudioWaveformBarModel(barCount: 5)
        var sums = Array(repeating: CGFloat(0), count: 5)
        var now: TimeInterval = 10

        for _ in 0..<600 {
            let heights = model.advance(to: now, level: 1, setup: false)
            for (index, height) in heights.enumerated() { sums[index] += height }
            now += frame
        }

        XCTAssertGreaterThan(sums[2], sums[0])
        XCTAssertGreaterThan(sums[2], sums[4])
    }

    func testReleaseIsSlowerThanAttack() {
        var model = AudioWaveformBarModel(barCount: 5)
        let raised = run(&model, from: 10, seconds: 1, level: 1)

        let dropped = model.advance(to: 11, level: 0, setup: false)

        for (before, after) in zip(raised, dropped) {
            XCTAssertGreaterThan(after, before * 0.8)
            XCTAssertLessThan(after, before)
        }
    }

    func testLevelIsClamped() {
        var model = AudioWaveformBarModel(barCount: 3)

        let heights = run(&model, from: 10, seconds: 1, level: 4)

        XCTAssertTrue(heights.allSatisfy { $0 <= 1 })
    }

    func testSetupBounceMovesAcrossBars() {
        var model = AudioWaveformBarModel(barCount: 5)
        var tallest = Set<Int>()
        var now: TimeInterval = 10

        for _ in 0..<60 {
            let heights = model.advance(to: now, level: 0, setup: true)
            if let index = heights.indices.max(by: { heights[$0] < heights[$1] }) {
                tallest.insert(index)
            }
            now += frame
        }

        XCTAssertEqual(tallest, Set(0..<5))
    }
}
