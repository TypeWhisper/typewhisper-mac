#if APPSTORE
import SwiftUI

/// A missing input permission of the App Store edition with a button that requests it.
struct AppStorePermissionRow: View {
    enum Kind {
        /// PostEvent access, listed under Accessibility in System Settings.
        case accessibility
        /// ListenEvent access, listed under Input Monitoring in System Settings.
        case inputMonitoring
    }

    enum TitleStyle {
        case short
        case explanatory
    }

    @ObservedObject var dictation: DictationViewModel
    let kind: Kind
    var titleStyle: TitleStyle = .explanatory
    var labelColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let labelColor {
                    label.foregroundStyle(labelColor)
                } else {
                    label
                }

                Spacer()

                Button(String(localized: "Grant Access")) {
                    switch kind {
                    case .accessibility:
                        dictation.requestAccessibilityPermission()
                    case .inputMonitoring:
                        dictation.requestInputMonitoringPermission()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            AppStorePermissionRestartHint(dictation: dictation, kind: kind)
        }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
    }

    private var systemImage: String {
        switch kind {
        case .accessibility: "lock.shield"
        case .inputMonitoring: "keyboard"
        }
    }

    private var title: String {
        switch (kind, titleStyle) {
        case (.accessibility, .short):
            AppStoreInputAccess.postEventSettingsName
        case (.accessibility, .explanatory):
            localizedAppText(
                "\(AppStoreInputAccess.postEventSettingsName) needed to paste automatically",
                de: "\(AppStoreInputAccess.postEventSettingsName) zum automatischen Einfügen nötig"
            )
        case (.inputMonitoring, .short):
            AppStoreInputAccess.listenEventSettingsName
        case (.inputMonitoring, .explanatory):
            localizedAppText(
                "Input Monitoring needed for your shortcuts",
                de: "Eingabeüberwachung für deine Kurzbefehle nötig"
            )
        }
    }
}
#endif
