import SwiftUI
import ServiceManagement

struct GeneralPage: View {
    @ObservedObject private var launchAtLogin = ServiceContainer.shared.launchAtLoginController

    var body: some View {
        DictumPageFrame(page: .general, actions: {
            if launchAtLogin.requiresApproval {
                Button { SMAppService.openSystemSettingsLoginItems() } label: {
                    Text("Open Login Items", tableName: "DictumShell")
                }.buttonStyle(.bordered).controlSize(.small).tint(.primary)
            }
        }) {
            ScrollView {
                VStack(spacing: 22) {
                    ShortcutsSection()
                    PolishStrengthSection()
                    TranslationLanguagesSection()
                    SoundSection()
                    HistorySyncSection()
                    AppSection()
                }
                .frame(maxWidth: 600)
                .padding(.top, 4).padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}
