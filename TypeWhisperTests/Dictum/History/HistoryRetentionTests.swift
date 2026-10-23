import XCTest
@testable import TypeWhisper

final class HistoryRetentionTests: XCTestCase {
    @MainActor
    func testRetentionCountAndDeletionAgree() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-retention")
        defer { TestSupport.remove(root) }
        let service = HistoryService(appSupportDirectory: root, eventEmitter: { _ in })
        let now = Date()
        for days in [0, 2, 40] {
            XCTAssertTrue(service.addRecord(timestamp: now.addingTimeInterval(Double(-days * 86400)), rawText: "会议记录", finalText: "会议记录。", appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        }
        XCTAssertEqual(service.retentionDeletionCount(.week, now: now), 1)
        service.applyRetention(.week, now: now)
        XCTAssertEqual(service.recordCount(), 2)
        service.applyRetention(.day, now: now)
        XCTAssertEqual(service.recordCount(), 1)
        service.applyRetention(.forever, now: now)
        XCTAssertEqual(service.recordCount(), 1)
        XCTAssertEqual(service.retentionDeletionCount(.never, now: now), 1)
        service.applyRetention(.never, now: now)
        XCTAssertEqual(service.recordCount(), 0)
    }

    func testCalendarMonthAndNever() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31))!
        XCTAssertEqual(HistoryRetention.month.cutoff(now: date, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 2, day: 28)))
        XCTAssertNil(HistoryRetention.forever.cutoff(now: date))
        XCTAssertEqual(HistoryRetention.never.cutoff(now: date), date)
    }
}
