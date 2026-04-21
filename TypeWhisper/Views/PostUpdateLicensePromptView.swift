import AppKit
import SwiftUI

struct PostUpdateLicensePromptView: View {
    let onPersonalOSS: () -> Void
    let onWorkUsage: () -> Void
    let onExistingKey: () -> Void
    let onBecomeSupporter: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer()

                Button(action: onNotNow) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizedAppText("Close", de: "Schließen"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(localizedAppText("Using TypeWhisper professionally?", de: "Nutzt du TypeWhisper beruflich?"))
                    .font(.title2.weight(.semibold))

                Text(localizedAppText(
                    "Private and GPL-compatible open-source use stays free. If you use TypeWhisper for work, please get a license.",
                    de: "Private Nutzung und GPL-kompatible Open-Source-Arbeit bleiben kostenlos. Wenn du TypeWhisper beruflich nutzt, hole dir bitte eine Lizenz."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                actionCard(
                    title: localizedAppText("Private / OSS", de: "Privat / OSS"),
                    description: localizedAppText(
                        "Keep using it for personal work and compliant open source.",
                        de: "Nutze es weiter privat oder für kompatible Open-Source-Arbeit."
                    ),
                    systemImage: "person",
                    emphasized: false,
                    action: onPersonalOSS
                )

                actionCard(
                    title: localizedAppText("I use it for work", de: "Ich nutze es beruflich"),
                    description: localizedAppText(
                        "Open the licensing options and keep this reminder active until a license is in place.",
                        de: "Öffne die Lizenzoptionen und behalte diese Erinnerung aktiv, bis eine Lizenz hinterlegt ist."
                    ),
                    systemImage: "briefcase.fill",
                    emphasized: true,
                    action: onWorkUsage
                )

                actionCard(
                    title: localizedAppText("I already have a key", de: "Ich habe schon einen Schlüssel"),
                    description: localizedAppText(
                        "Jump straight to the activation field in License settings.",
                        de: "Springe direkt zum Aktivierungsfeld in den Lizenz-Einstellungen."
                    ),
                    systemImage: "key.fill",
                    emphasized: false,
                    action: onExistingKey
                )
            }

            HStack {
                Button(localizedAppText("Become a supporter", de: "Supporter werden"), action: onBecomeSupporter)
                    .buttonStyle(.link)

                Spacer()

                Button(localizedAppText("Not now", de: "Später"), action: onNotNow)
                    .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private func actionCard(
        title: String,
        description: String,
        systemImage: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(emphasized ? .white : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(emphasized ? .white : .primary)

                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(emphasized ? .white.opacity(0.86) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(emphasized ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(emphasized ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
