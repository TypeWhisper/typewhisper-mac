import SwiftUI

struct WelcomeSheet: View {
    @ObservedObject private var license = LicenseService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text(String(localized: "Welcome to TypeWhisper!"))
                .font(.title2.bold())

            Text(String(localized: "TypeWhisper is open source.\nPersonal use and GPL-compliant open-source use are free.\nProprietary or otherwise non-GPL-compliant use requires a commercial license."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    license.setUserType(.privateUser)
                    dismiss()
                } label: {
                    Label(String(localized: "Personal or open source"), systemImage: "person")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button {
                    license.setUserType(.business)
                    dismiss()
                } label: {
                    Label(String(localized: "Proprietary use"), systemImage: "building.2")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 440)
    }
}
