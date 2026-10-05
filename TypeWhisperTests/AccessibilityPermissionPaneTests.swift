import XCTest
@testable import TypeWhisper

/// macOS 27 renamed System Settings > Privacy & Security > Accessibility to
/// "Device Control and Data Access". Permission hints must name the pane the
/// user actually sees on the running OS.
final class AccessibilityPermissionPaneTests: XCTestCase {
    private var originalPreferredAppLanguage: String?

    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
    private let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
    private let macOS27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
    private let macOS28 = OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)

    override func setUp() {
        super.setUp()
        originalPreferredAppLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
    }

    override func tearDown() {
        if let originalPreferredAppLanguage {
            UserDefaults.standard.set(originalPreferredAppLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
        }
        super.tearDown()
    }

    func testDeviceControlNameStartsWithMacOS27() {
        XCTAssertFalse(AccessibilityPermissionPane.usesDeviceControlName(osVersion: sonoma))
        XCTAssertFalse(AccessibilityPermissionPane.usesDeviceControlName(osVersion: tahoe))
        XCTAssertTrue(AccessibilityPermissionPane.usesDeviceControlName(osVersion: macOS27))
        XCTAssertTrue(AccessibilityPermissionPane.usesDeviceControlName(osVersion: macOS28))
    }

    func testTextSelectsVariantForOSVersion() {
        XCTAssertEqual(
            AccessibilityPermissionPane.text(legacy: "legacy", deviceControl: "new", osVersion: tahoe),
            "legacy"
        )
        XCTAssertEqual(
            AccessibilityPermissionPane.text(legacy: "legacy", deviceControl: "new", osVersion: macOS27),
            "new"
        )
    }

    func testPaneNameOnMacOS27MatchesSystemSettingsInEachLanguage() {
        let expected = [
            "en": "Device Control and Data Access",
            "de": "Gerätesteuerung und Datenzugriff",
            "ja": "デバイスの制御とデータへのアクセス",
            "zh-Hans": "设备控制和数据访问",
        ]

        for (language, name) in expected {
            UserDefaults.standard.set(language, forKey: UserDefaultsKeys.preferredAppLanguage)
            XCTAssertEqual(AccessibilityPermissionPane.localizedName(osVersion: macOS27), name, language)
        }
    }

    func testSystemSettingsInstructionNamesPaneForOSVersion() {
        UserDefaults.standard.set("en", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(
            AccessibilityPermissionPane.enableInSystemSettingsText(osVersion: tahoe),
            "Accessibility permission not granted. Please enable it in System Settings → Privacy & Security → Accessibility."
        )
        XCTAssertEqual(
            AccessibilityPermissionPane.enableInSystemSettingsText(osVersion: macOS27),
            "Device Control and Data Access permission not granted. Please enable it in System Settings → Privacy & Security → Device Control and Data Access."
        )

        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertTrue(
            AccessibilityPermissionPane.enableInSystemSettingsText(osVersion: tahoe)
                .hasSuffix("Datenschutz & Sicherheit → Bedienungshilfen.")
        )
        XCTAssertTrue(
            AccessibilityPermissionPane.enableInSystemSettingsText(osVersion: macOS27)
                .hasSuffix("Datenschutz & Sicherheit → Gerätesteuerung und Datenzugriff.")
        )
    }

    func testAccessRequiredTextOnMacOS27NamesNewPane() {
        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)
        XCTAssertEqual(
            AccessibilityPermissionPane.accessRequiredText(osVersion: macOS27),
            "Berechtigung „Gerätesteuerung und Datenzugriff“ erforderlich"
        )
    }
}
