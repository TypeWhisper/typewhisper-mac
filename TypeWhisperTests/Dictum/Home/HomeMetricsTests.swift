import XCTest
@testable import TypeWhisper

final class HomeMetricsTests: XCTestCase {
    func testHeatLevelBoundaries() {
        XCTAssertEqual([0, 1, 249, 250, 599, 600, 1099, 1100].map(HomeMetrics.heatLevel), [0, 1, 1, 2, 2, 3, 3, 4])
    }

    func testStreakAllowsTodayWithoutActivityAndUsesCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let days = try [-5, -4, -2, -1].map { offset in
            UsageStatisticsDaySnapshot(day: try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today)), transcriptionCount: 1, totalWords: 7, totalDurationSeconds: 3, appBundleIdentifiers: [])
        }
        let streak = HomeMetrics.streaks(days, today: today, calendar: calendar)
        XCTAssertEqual(streak.current, 2)
        XCTAssertEqual(streak.longest, 2)
        let afterGap = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(HomeMetrics.streaks(days, today: afterGap, calendar: calendar).current, 0)
    }

    func testEmptyStatisticsHaveNoStreakOrInventedGrowth() {
        XCTAssertEqual(HomeMetrics.streaks([]).current, 0)
        XCTAssertEqual(HomeMetrics.streaks([]).longest, 0)
        XCTAssertEqual(HomeMetrics.delta(10, 0), "—")
    }
}
