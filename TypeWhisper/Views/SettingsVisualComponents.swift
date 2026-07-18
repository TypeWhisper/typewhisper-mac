import SwiftUI

enum SettingsLayoutMetrics {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 8
}

struct SettingsPageHeader<Actions: View>: View {
    let title: String
    let summary: String?
    @ViewBuilder let actions: Actions

    init(
        _ title: String,
        summary: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.summary = summary
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))

                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            actions
                .controlSize(.small)
        }
        .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

extension SettingsPageHeader where Actions == EmptyView {
    init(_ title: String, summary: String? = nil) {
        self.init(title, summary: summary) {
            EmptyView()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let selected: Bool
    let accent: Color
    @ViewBuilder let content: Content

    init(
        selected: Bool = false,
        accent: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.selected = selected
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(SettingsLayoutMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                    .stroke(
                        selected ? accent.opacity(0.8) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
    }
}

struct SettingsEmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let action: Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            action
        }
        .padding(SettingsLayoutMetrics.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SettingsEmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) {
            EmptyView()
        }
    }
}
