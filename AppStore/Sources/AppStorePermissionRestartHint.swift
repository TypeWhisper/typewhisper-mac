#if APPSTORE
import AppKit
import SwiftUI

/// Shown when a requested input permission is still not in effect after the
/// user returned to TypeWhisper. macOS may apply a newly granted permission
/// only to a new process, so this offers the restart.
struct AppStorePermissionRestartHint: View {
    @ObservedObject var dictation: DictationViewModel
    let kind: AppStorePermissionRow.Kind

    private var isPending: Bool {
        switch kind {
        case .accessibility: AppStoreInputAccess.postEventAccessPending
        case .inputMonitoring: AppStoreInputAccess.listenEventAccessPending
        }
    }

    var body: some View {
        Group {
            if isPending {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(localizedAppText(
                        "Turned it on? Restart TypeWhisper to finish.",
                        de: "Eingeschaltet? Starte TypeWhisper neu, damit es wirkt."
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button(localizedAppText("Restart", de: "Neu starten")) {
                        ApplicationRelauncher.relaunch()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            dictation.refreshInputPermissions()
        }
    }
}
#endif
