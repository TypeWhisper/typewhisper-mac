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

    /// Status line shown while the permission is missing. Dictation works without it and
    /// leaves the text on the clipboard instead (#1906).
    static func neededToPasteText(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let name = localizedName(osVersion: osVersion)
        return localizedAppText(
            "\(name) needed to paste automatically",
            de: "\(name) zum automatischen Einfügen nötig",
            ja: "自動で貼り付けるには「\(name)」が必要です",
            zh: "需要“\(name)”才能自动粘贴",
            es: "Se necesita \(name) para pegar automáticamente"
        )
    }

    /// Feedback after text was copied to the clipboard because the permission is missing.
    static func manualPasteMessage(
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let name = localizedName(osVersion: osVersion)
        return localizedAppText(
            "Copied to clipboard. Press ⌘V to paste, or allow TypeWhisper under \u{201C}\(name)\u{201D} to paste automatically.",
            de: "In die Zwischenablage kopiert. Füge den Text mit ⌘V ein oder erlaube TypeWhisper unter „\(name)“, um automatisch einzufügen.",
            ja: "クリップボードにコピーしました。⌘V で貼り付けるか、「\(name)」で TypeWhisper を許可すると自動で貼り付けられます。",
            zh: "已复制到剪贴板。按 ⌘V 粘贴，或在“\(name)”中允许 TypeWhisper 以自动粘贴。",
            es: "Copiado en el portapapeles. Presiona ⌘V para pegar o permite TypeWhisper en “\(name)” para pegar automáticamente."
        )
    }
}
