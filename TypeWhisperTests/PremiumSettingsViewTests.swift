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

    func testCorrectionExamplesFollowTheSelectedLanguage() {
        let english = PremiumCorrectionExamples.examples(for: "en")
        XCTAssertEqual(
            english.map(\.before),
            ["teh", "recieve"]
        )
        XCTAssertEqual(english.map(\.after), ["the", "receive"])

        let german = PremiumCorrectionExamples.examples(for: "de-DE")
        XCTAssertEqual(
            german.map(\.before),
            ["Standart", "wiederspiegeln"]
        )
        XCTAssertEqual(german.map(\.after), ["Standard", "widerspiegeln"])

        let japanese = PremiumCorrectionExamples.examples(for: "ja-JP")
        XCTAssertEqual(japanese.map(\.before), ["こんにちわ", "すいません"])
        XCTAssertEqual(
            japanese.map(\.after),
            ["こんにちは", "すみません"]
        )

        let simplifiedChinese = PremiumCorrectionExamples.examples(for: "zh-Hans")
        XCTAssertEqual(simplifiedChinese.map(\.before), ["因该", "在次"])
        XCTAssertEqual(
            simplifiedChinese.map(\.after),
            ["应该", "再次"]
        )
    }

    @MainActor
    func testLockedOverviewStoresNoOSServiceControllerOrWindowPresenter() {
        let preview = PremiumLockedFeatureOverview(isSupporter: false, onUnlock: {})
        let labels = Mirror(reflecting: preview).children.compactMap(\.label)

        XCTAssertEqual(labels, ["isSupporter", "onUnlock"])
        XCTAssertFalse(labels.contains("controller"))
        XCTAssertFalse(labels.contains("windowPresenter"))
    }

    func testFeatureAccessSnapshotPreservesExistingEntitlementRules() {
        let free = access()
        XCTAssertEqual(free.summary, .locked)
        XCTAssertEqual(free.requirement(for: .calendarMeeting), .commercialOrPremiumAccount)
        XCTAssertEqual(free.requirement(for: .correctionLearning), .commercialLicense)
        XCTAssertEqual(free.requirement(for: .cloudSync), .premiumAccount)

        let supporter = access(isSupporter: true)
        XCTAssertEqual(supporter.summary, .supporterOnly)
        XCTAssertFalse(supporter.hasAnyPremiumAccess)

        let commercial = access(hasCommercialLicense: true)
        XCTAssertEqual(commercial.summary, .commercialLicense)
        XCTAssertEqual(commercial.requirement(for: .calendarMeeting), .available)
        XCTAssertEqual(commercial.requirement(for: .correctionLearning), .available)
        XCTAssertEqual(commercial.requirement(for: .cloudSync), .premiumAccount)

        let signedInCommercial = access(
            hasCommercialLicense: true,
            isSignedIn: true
        )
        XCTAssertEqual(
            signedInCommercial.requirement(for: .cloudSync),
            .linkCommercialLicense
        )
        XCTAssertEqual(signedInCommercial.action(for: .cloudSync), .manageAccess)

        let account = access(hasPremiumEntitlement: true, isSignedIn: true)
        XCTAssertEqual(account.summary, .premiumAccount)
        XCTAssertEqual(account.requirement(for: .calendarMeeting), .available)
        XCTAssertEqual(account.requirement(for: .correctionLearning), .commercialLicense)
        XCTAssertEqual(account.requirement(for: .cloudSync), .available)

        let signedOutAccount = access(hasPremiumEntitlement: true, isSignedIn: false)
        XCTAssertEqual(signedOutAccount.requirement(for: .cloudSync), .signIn)

        let both = access(
            hasCommercialLicense: true,
            hasPremiumEntitlement: true,
            isSignedIn: true
        )
        XCTAssertEqual(both.summary, .commercialAndPremiumAccount)
        for feature in PremiumFeatureID.allCases {
            XCTAssertEqual(both.requirement(for: feature), .available)
        }
    }

    func testFeatureActionsOpenOnlyAvailableSettings() {
        let free = access()
        for feature in PremiumFeatureID.allCases {
            XCTAssertEqual(free.action(for: feature), .none)
        }

        let commercial = access(hasCommercialLicense: true)
        XCTAssertEqual(commercial.action(for: .calendarMeeting), .openSettings(.calendarMeeting))
        XCTAssertEqual(commercial.action(for: .correctionLearning), .openSettings(.correctionLearning))
        XCTAssertEqual(commercial.action(for: .cloudSync), .manageAccess)

        let account = access(hasPremiumEntitlement: true, isSignedIn: true)
        XCTAssertEqual(account.action(for: .calendarMeeting), .openSettings(.calendarMeeting))
        XCTAssertEqual(account.action(for: .correctionLearning), .manageAccess)
        XCTAssertEqual(account.action(for: .cloudSync), .openSettings(.cloudSync))
    }

    func testEveryLicenseAccountSignInAndSupporterCombinationUsesTheDocumentedGates() {
        for hasCommercialLicense in [false, true] {
            for hasPremiumEntitlement in [false, true] {
                for isSignedIn in [false, true] {
                    for isSupporter in [false, true] {
                        let snapshot = access(
                            hasCommercialLicense: hasCommercialLicense,
                            hasPremiumEntitlement: hasPremiumEntitlement,
                            isSignedIn: isSignedIn,
                            isSupporter: isSupporter
                        )

                        XCTAssertEqual(
                            snapshot.requirement(for: .calendarMeeting) == .available,
                            hasCommercialLicense || hasPremiumEntitlement
                        )
                        XCTAssertEqual(
                            snapshot.requirement(for: .correctionLearning) == .available,
                            hasCommercialLicense
                        )
                        XCTAssertEqual(
                            snapshot.requirement(for: .cloudSync) == .available,
                            hasPremiumEntitlement && isSignedIn
                        )

                        if !hasCommercialLicense && !hasPremiumEntitlement {
                            XCTAssertEqual(
                                snapshot.summary,
                                isSupporter ? .supporterOnly : .locked
                            )
                            XCTAssertEqual(snapshot.action(for: .calendarMeeting), .none)
                            XCTAssertEqual(snapshot.action(for: .correctionLearning), .none)
                            XCTAssertEqual(snapshot.action(for: .cloudSync), .none)
                        }
                    }
                }
            }
        }
    }

    func testPremiumHubAndDetailKeysAreLocalizedInAllSupportedLanguages() throws {
        let root = repositoryRoot
        let data = try Data(contentsOf: root.appendingPathComponent(
            "TypeWhisper/Resources/Localizable.xcstrings"
        ))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
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
            "calendarMeeting.settings.autoStopNotificationsRequired",
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
            "calendarMeeting.notification.continueAction",
        ]
        let premiumKeys = strings.keys.filter {
            $0.hasPrefix("premium.hub.")
                || $0.hasPrefix("premium.window.")
                || $0.hasPrefix("premium.common.")
        }
        XCTAssertGreaterThan(premiumKeys.count, 70)

        for key in Set(calendarKeys + premiumKeys).sorted() {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for locale in ["en", "de", "ja", "zh-Hans"] {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale) for \(key)"
                )
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertFalse(value.isEmpty, "Empty \(locale) value for \(key)")
            }
        }
    }

    func testPlistHasCalendarUsageCopyAndCalendarEntitlement() throws {
        let root = repositoryRoot
        let plistData = try Data(contentsOf: root.appendingPathComponent("TypeWhisper/Resources/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let usage = try XCTUnwrap(plist["NSCalendarsFullAccessUsageDescription"] as? String)
        XCTAssertFalse(usage.isEmpty)

        let entitlementData = try Data(contentsOf: root.appendingPathComponent(
            "TypeWhisper/Resources/TypeWhisper.entitlements"
        ))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: entitlementData,
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            entitlements["com.apple.security.personal-information.calendars"] as? Bool,
            true
        )
    }

    func testLocalCalendarSettingsAreNotPartOfBackupExporter() throws {
        let exporter = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "TypeWhisper/Services/SettingsBackupExporter.swift"
        ), encoding: .utf8)
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingStartMode))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSelectedCalendarIDs))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests))
        XCTAssertFalse(exporter.contains(UserDefaultsKeys.calendarMeetingReminderRequestDigests))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func access(
        hasCommercialLicense: Bool = false,
        hasPremiumEntitlement: Bool = false,
        isSignedIn: Bool = false,
        isSupporter: Bool = false
    ) -> PremiumFeatureAccessSnapshot {
        PremiumFeatureAccessSnapshot(
            hasCommercialLicense: hasCommercialLicense,
            hasPremiumEntitlement: hasPremiumEntitlement,
            isSignedIn: isSignedIn,
            isSupporter: isSupporter
        )
    }
}
