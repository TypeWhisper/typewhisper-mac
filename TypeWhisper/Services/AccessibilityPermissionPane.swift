import Foundation

/// User-facing naming for the System Settings > Privacy & Security pane that
/// grants the Accessibility (AX) permission.
///
/// macOS 27 renamed the pane from "Accessibility" to "Device Control and Data
/// Access". The permission and the AX API are unchanged, so only texts that tell
/// the user where to enable TypeWhisper should use this helper.
enum AccessibilityPermissionPane {
    /// The major macOS version that introduced the "Device Control and Data Access" name.
    static let deviceControlRenameMajorVersion = 27

    static func usesDeviceControlName(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        osVersion.majorVersion >= deviceControlRenameMajorVersion
    }

    /// Picks the text that matches the pane name on the running macOS version.
    static func text(
        legacy: @autoclosure () -> String,
        deviceControl: @autoclosure () -> String,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        usesDeviceControlName(osVersion: osVersion) ? deviceControl() : legacy()
    }

    /// The pane name as shown in System Settings > Privacy & Security.
    static func localizedName(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        text(
            legacy: String(localized: "Accessibility"),
            deviceControl: localizedAppText(
                "Device Control and Data Access",
                de: "Gerätesteuerung und Datenzugriff",
                ja: "デバイスの制御とデータへのアクセス",
                zh: "设备控制和数据访问"
            ),
            osVersion: osVersion
        )
    }

    /// Short status line shown when the permission is missing.
    static func accessRequiredText(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        text(
            legacy: String(localized: "Accessibility access required"),
            deviceControl: localizedAppText(
                "Device Control and Data Access permission required",
                de: "Berechtigung „Gerätesteuerung und Datenzugriff“ erforderlich",
                ja: "「デバイスの制御とデータへのアクセス」の権限が必要です",
                zh: "需要“设备控制和数据访问”权限"
            ),
            osVersion: osVersion
        )
    }

    /// Full instruction naming the System Settings path to the pane.
    static func enableInSystemSettingsText(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        text(
            legacy: localizedAppText(
                "Accessibility permission not granted. Please enable it in System Settings → Privacy & Security → Accessibility.",
                de: "Die Berechtigung für Bedienungshilfen wurde nicht erteilt. Bitte aktiviere sie unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen.",
                ja: "アクセシビリティの権限が許可されていません。システム設定 → プライバシーとセキュリティ → アクセシビリティで有効にしてください。",
                zh: "未授予辅助功能权限。请在“系统设置”→“隐私与安全性”→“辅助功能”中启用。"
            ),
            deviceControl: localizedAppText(
                "Device Control and Data Access permission not granted. Please enable it in System Settings → Privacy & Security → Device Control and Data Access.",
                de: "Die Berechtigung „Gerätesteuerung und Datenzugriff“ wurde nicht erteilt. Bitte aktiviere sie unter Systemeinstellungen → Datenschutz & Sicherheit → Gerätesteuerung und Datenzugriff.",
                ja: "「デバイスの制御とデータへのアクセス」の権限が許可されていません。システム設定 → プライバシーとセキュリティ → デバイスの制御とデータへのアクセスで有効にしてください。",
                zh: "未授予“设备控制和数据访问”权限。请在“系统设置”→“隐私与安全性”→“设备控制和数据访问”中启用。"
            ),
            osVersion: osVersion
        )
    }
}
