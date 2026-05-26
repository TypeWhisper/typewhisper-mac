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

            Text(String(localized: "Choose the scenario closest to you. You can change it later in Settings > License."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                welcomeChoiceButton(
                    intent: .personalOSS,
                    title: String(localized: "GPLv3 / OSS"),
                    description: String(localized: "Install and run the GPL version as-is, including personal or internal use."),
                    systemImage: "person"
                )

                welcomeChoiceButton(
                    intent: .workSolo,
                    title: String(localized: "Commercial license"),
                    description: String(localized: "Non-GPL terms, procurement, support, or proprietary distribution for one person."),
                    systemImage: "briefcase"
                )

                welcomeChoiceButton(
                    intent: .team,
                    title: String(localized: "With a team"),
                    description: String(localized: "Procurement, support, managed seats, and multi-device rollout."),
                    systemImage: "person.3"
                )
            }
        }
        .padding(32)
        .frame(width: 520)
    }

    private func welcomeChoiceButton(
        intent: UsageIntent,
        title: String,
        description: String,
        systemImage: String
    ) -> some View {
        Button {
            license.setUsageIntent(intent)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }
}
