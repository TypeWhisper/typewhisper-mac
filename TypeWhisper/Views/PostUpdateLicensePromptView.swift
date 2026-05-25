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
                .accessibilityLabel(String(localized: "Close"))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Need commercial license terms?"))
                    .font(.title2.weight(.semibold))

                Text(String(localized: "You can keep using the GPL version as-is. Choose a commercial license if you need non-GPL terms, procurement, support, or proprietary redistribution."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                actionCard(
                    title: String(localized: "GPLv3 / OSS"),
                    description: String(localized: "Keep using the GPL version as-is."),
                    systemImage: "person",
                    emphasized: false,
                    action: onPersonalOSS
                )

                actionCard(
                    title: String(localized: "Show commercial options"),
                    description: String(localized: "Open licensing for non-GPL terms, procurement, support, or proprietary redistribution."),
                    systemImage: "briefcase.fill",
                    emphasized: true,
                    action: onWorkUsage
                )

                actionCard(
                    title: String(localized: "I already have a key"),
                    description: String(localized: "Jump straight to the activation field in License settings."),
                    systemImage: "key.fill",
                    emphasized: false,
                    action: onExistingKey
                )
            }

            HStack {
                Button(String(localized: "Become a supporter"), action: onBecomeSupporter)
                    .buttonStyle(.link)

                Spacer()

                Button(String(localized: "Not now"), action: onNotNow)
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
