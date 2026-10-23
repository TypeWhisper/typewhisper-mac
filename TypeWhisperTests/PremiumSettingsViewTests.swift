import Foundation
import XCTest
@testable import TypeWhisper

final class PremiumSettingsViewTests: XCTestCase {
    @MainActor
    func testEveryFeatureNavigatesWithoutAnAccount() throws {
        let navigation = SettingsNavigationCoordinator()
        let destinations: [PremiumFeatureID: SettingsTab] = [
            .calendarMeeting: .recorder,
            .correctionLearning: .dictionary,
            .cloudSync: .history,
            .speakerWorkspace: .speakers
        ]
        for feature in PremiumFeatureID.allCases {
            navigation.navigate(to: feature)
            XCTAssertEqual(try XCTUnwrap(navigation.request).tab, destinations[feature])
        }
        XCTAssertEqual(navigation.recorderPart, .meetings)
        XCTAssertEqual(navigation.dictionaryPart, .learning)
        XCTAssertEqual(navigation.historyPart, .sync)
    }

    func testCorrectionExamplesFollowTheSelectedLanguage() {
        let english = PremiumCorrectionExamples.examples(for: "en")
        XCTAssertEqual(english.map(\.before), ["teh", "recieve"])
        XCTAssertEqual(english.map(\.after), ["the", "receive"])
        let german = PremiumCorrectionExamples.examples(for: "de-DE")
        XCTAssertEqual(german.map(\.before), ["Standart", "wiederspiegeln"])
        XCTAssertEqual(german.map(\.after), ["Standard", "widerspiegeln"])
        let japanese = PremiumCorrectionExamples.examples(for: "ja-JP")
        XCTAssertEqual(japanese.map(\.before), ["こんにちわ", "すいません"])
        XCTAssertEqual(japanese.map(\.after), ["こんにちは", "すみません"])
        let chinese = PremiumCorrectionExamples.examples(for: "zh-Hans")
        XCTAssertEqual(chinese.map(\.before), ["因该", "在次"])
        XCTAssertEqual(chinese.map(\.after), ["应该", "再次"])
    }

    func testFeatureDetailKeysAreLocalizedInAllSupportedLanguages() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "TypeWhisper/Resources/Localizable.xcstrings"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        let calendarKeys = [
            "calendarMeeting.settings.title",
            "calendarMeeting.settings.description",
            "calendarMeeting.settings.startMode",
            "calendarMeeting.settings.recordingStart",
            "calendarMeeting.settings.startModeHelp",
            "calendarMeeting.settings.permissions",
            "calendarMeeting.settings.calendarsHelp",
            "calendarMeeting.settings.providersHelp",
            "calendarMeeting.settings.stopping",
            "calendarMeeting.settings.howItWorks",
            "calendarMeeting.settings.autoStop",
            "calendarMeeting.settings.autoStopHelp",
            "calendarMeeting.settings.autoStopNotificationsOptional",
            "calendarMeeting.settings.detectAdHoc",
            "calendarMeeting.settings.detectAdHocHelp",
            "calendarMeeting.settings.adHocAutoStopHelp",
            "calendarMeeting.detected.titleFormat",
            "calendarMeeting.settings.notificationHelp",
            "calendarMeeting.settings.privacy",
            "calendarMeeting.settings.requestCalendarAccess",
            "calendarMeeting.settings.requestingCalendarAccess",
            "calendarMeeting.mode.reminder",
            "calendarMeeting.mode.automatic",
            "calendarMeeting.permission.calendarRestricted",
            "calendarMeeting.permission.calendarRestrictedHelp",
            "calendarMeeting.permission.requestFailedTitle",
            "calendarMeeting.permission.requestFailedMessage",
            "calendarMeeting.countdown.cancel",
            "calendarMeeting.notification.armWhenJoinedAction",
            "calendarMeeting.notification.inProgressTitle",
            "calendarMeeting.notification.upcomingAutomaticBody",
            "calendarMeeting.notification.autoStopTitle",
            "calendarMeeting.notification.autoStopBody",
            "calendarMeeting.notification.continueAction"
        ]
        let keys = calendarKeys + strings.keys.filter {
            $0.hasPrefix("premium.window.learning.") || $0.hasPrefix("premium.window.sync.")
        }
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["en", "de", "ja", "zh-Hans"] {
                let localization = try XCTUnwrap(localizations[language] as? [String: Any], "\(key): \(language)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertFalse(try XCTUnwrap(unit["value"] as? String).isEmpty)
            }
        }
    }

    func testPlistHasCalendarUsageCopyAndCalendarEntitlement() throws {
        let plistData = try Data(contentsOf: repositoryRoot.appendingPathComponent("TypeWhisper/Resources/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(plist["NSCalendarsFullAccessUsageDescription"] as? String).isEmpty)
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "TypeWhisper/Resources/TypeWhisper.entitlements"
        ))
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.personal-information.calendars"] as? Bool, true)
    }

    func testLocalCalendarSettingsAreNotPartOfBackupExporter() throws {
        let exporter = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TypeWhisper/Services/SettingsBackupExporter.swift"
        ), encoding: .utf8)
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingStartMode))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingDetectAdHoc))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSelectedCalendarIDs))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingReminderRequestDigests))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
