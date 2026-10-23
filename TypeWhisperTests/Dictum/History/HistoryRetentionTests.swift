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

    func testStoredDaysTheEnumDoesNotKnowMapToTheNearestLongerLevel() throws {
        XCTAssertEqual(HistoryRetention(storedDays: 60), .year)
        XCTAssertEqual(HistoryRetention(storedDays: 90), .year)
        XCTAssertEqual(HistoryRetention(storedDays: 180), .year)
        XCTAssertEqual(HistoryRetention(storedDays: 14), .month)
        XCTAssertEqual(HistoryRetention(storedDays: 3), .week)
        XCTAssertEqual(HistoryRetention(storedDays: 400), .forever)
        XCTAssertEqual(HistoryRetention(storedDays: 30), .month)
        XCTAssertEqual(HistoryRetention(storedDays: 0), .forever)
        XCTAssertEqual(HistoryRetention(storedDays: -1), .never)
        let suite = "dictum-retention-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(90, forKey: UserDefaultsKeys.historyRetentionDays)
        XCTAssertEqual(HistoryRetention.selected(in: defaults), .year)
    }

    @MainActor
    func testUnknownLegacyRetentionDaysDeleteNothingAtStartup() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-retention-legacy")
        defer { TestSupport.remove(root) }
        let service = HistoryService(appSupportDirectory: root, eventEmitter: { _ in })
        let now = Date()
        for days in [0, 70, 120, 200] {
            XCTAssertTrue(service.addRecord(timestamp: now.addingTimeInterval(Double(-days * 86400)), rawText: "旧记录", finalText: "旧记录。", appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "zh", engineUsed: "Qwen3-ASR"))
        }
        service.purgeOldRecords(retentionDays: 90)
        XCTAssertEqual(service.recordCount(), 4)
        service.purgeOldRecords(retentionDays: 60)
        XCTAssertEqual(service.recordCount(), 4)
        service.purgeOldRecords(retentionDays: 180)
        XCTAssertEqual(service.recordCount(), 4)
        service.purgeOldRecords(retentionDays: 30)
        XCTAssertEqual(service.recordCount(), 1)
        service.purgeOldRecords(retentionDays: 365)
        XCTAssertEqual(service.recordCount(), 1)
        service.purgeOldRecords(retentionDays: 0)
        XCTAssertEqual(service.recordCount(), 1)
        service.purgeOldRecords(retentionDays: 7)
        XCTAssertEqual(service.recordCount(), 1)
    }
}
