import Foundation
import XCTest
@testable import TypeWhisper

final class PremiumSettingsViewTests: XCTestCase {
    func testPremiumGateHasNoSupporterShortcut() {
        XCTAssertFalse(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: false,
            hasPremiumEntitlement: false
        ))
        XCTAssertTrue(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: true,
            hasPremiumEntitlement: false
        ))
        XCTAssertTrue(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: false,
            hasPremiumEntitlement: true
        ))
    }

    @MainActor
    func testFreePreviewStoresOnlyUpgradeActionAndNoOSServiceController() {
        let preview = CalendarMeetingFreePreviewSection(onUpgrade: {})
        let labels = Mirror(reflecting: preview).children.compactMap(\.label)

        XCTAssertEqual(labels, ["onUpgrade"])
        XCTAssertFalse(labels.contains("controller"))
    }

    func testCalendarSettingsKeysAreLocalizedInEnglishGermanAndJapanese() throws {
        let root = repositoryRoot
        let data = try Data(contentsOf: root.appendingPathComponent(
            "TypeWhisper/Resources/Localizable.xcstrings"
        ))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        let expectedKeys = [
            "calendarMeeting.settings.title",
            "calendarMeeting.settings.startMode",
            "calendarMeeting.settings.autoStop",
            "calendarMeeting.settings.privacy",
            "calendarMeeting.countdown.cancel",
            "calendarMeeting.countdown.continue",
        ]

        for key in expectedKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(localizations["en"], "Missing English for \(key)")
            XCTAssertNotNil(localizations["de"], "Missing German for \(key)")
            XCTAssertNotNil(localizations["ja"], "Missing Japanese for \(key)")
        }
    }

    func testPlistHasCalendarUsageCopyAndEntitlementsRemainCalendarFree() throws {
        let root = repositoryRoot
        let plistData = try Data(contentsOf: root.appendingPathComponent("TypeWhisper/Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let usage = try XCTUnwrap(plist["NSCalendarsFullAccessUsageDescription"] as? String)
        XCTAssertFalse(usage.isEmpty)

        let entitlements = try String(contentsOf: root.appendingPathComponent(
            "TypeWhisper/Resources/TypeWhisper.entitlements"
        ), encoding: .utf8)
        XCTAssertFalse(entitlements.localizedCaseInsensitiveContains("calendar"))
    }

    func testLocalCalendarSettingsAreNotPartOfBackupExporter() throws {
        let exporter = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TypeWhisper/Services/SettingsBackupExporter.swift"
        ), encoding: .utf8)
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingStartMode))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSelectedCalendarIDs))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
