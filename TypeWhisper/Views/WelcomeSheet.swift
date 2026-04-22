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

            Text(localizedAppText(
                "Choose the scenario closest to you. You can change it later in Settings > License.",
                de: "Wähle den Fall, der dir am nächsten kommt. Du kannst ihn später unter Einstellungen > Lizenz ändern."
            ))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                welcomeChoiceButton(
                    intent: .personalOSS,
                    title: localizedAppText("Private & OSS", de: "Privat & OSS"),
                    description: localizedAppText(
                        "Personal use and GPL-compatible open-source work stay free.",
                        de: "Private Nutzung und GPL-kompatible Open-Source-Arbeit bleiben kostenlos."
                    ),
                    systemImage: "person"
                )

                welcomeChoiceButton(
                    intent: .workSolo,
                    title: localizedAppText("At work, solo", de: "Beruflich allein"),
                    description: localizedAppText(
                        "Freelance work, day job usage, or closed-source projects for one person.",
                        de: "Freelance-Arbeit, Nutzung im Job oder Closed-Source-Projekte für eine Person."
                    ),
                    systemImage: "briefcase"
                )

                welcomeChoiceButton(
                    intent: .team,
                    title: localizedAppText("With a team", de: "Mit Team"),
                    description: localizedAppText(
                        "Shared rollout, multiple devices, and team-wide usage.",
                        de: "Gemeinsamer Rollout, mehrere Geräte und Team-Nutzung."
                    ),
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
