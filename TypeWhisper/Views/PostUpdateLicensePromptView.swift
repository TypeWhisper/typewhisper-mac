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
                Text(localizedAppText("Need commercial license terms?", de: "Brauchst du kommerzielle Lizenzbedingungen?"))
                    .font(.title2.weight(.semibold))

                Text(localizedAppText(
                    "You can keep using the GPL version as-is. Choose a commercial license if you need non-GPL terms, procurement, support, or proprietary redistribution.",
                    de: "Du kannst die GPL-Version unverändert weiter nutzen. Wähle eine kommerzielle Lizenz, wenn du Nicht-GPL-Bedingungen, Beschaffung, Support oder proprietäre Weiterverteilung brauchst."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                actionCard(
                    title: localizedAppText("GPLv3 / OSS", de: "GPLv3 / OSS"),
                    description: localizedAppText(
                        "Keep using the GPL version as-is.",
                        de: "Nutze die GPL-Version unverändert weiter."
                    ),
                    systemImage: "person",
                    emphasized: false,
                    action: onPersonalOSS
                )

                actionCard(
                    title: localizedAppText("Show commercial options", de: "Kommerzielle Optionen anzeigen"),
                    description: localizedAppText(
                        "Open licensing for non-GPL terms, procurement, support, or proprietary redistribution.",
                        de: "Öffne Lizenzen für Nicht-GPL-Bedingungen, Beschaffung, Support oder proprietäre Weiterverteilung."
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
