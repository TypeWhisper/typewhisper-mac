import SwiftUI

struct GroupedFormSection<Content: View>: View {
    let title: LocalizedStringKey
    var footer: LocalizedStringKey? = nil
    var tableName: String = "DictumShell"
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title, tableName: tableName)
                .font(DictumTheme.Typography.section)
                .frame(height: 19, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: DictumTheme.Layout.groupRadius))
                .overlay(RoundedRectangle(cornerRadius: DictumTheme.Layout.groupRadius).strokeBorder(DictumTheme.separator, lineWidth: 0.5))
            if let footer {
                Text(footer, tableName: tableName)
                    .font(DictumTheme.Typography.secondary)
                    .foregroundStyle(DictumTheme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupedFormRow<Content: View>: View {
    var separated = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12, content: content)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 14)
            .overlay(alignment: .top) {
                if separated { DictumTheme.separator.frame(height: 0.5).padding(.horizontal, 14) }
            }
    }
}

struct GroupedFormToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var separated = true
    var tableName: String = "DictumShell"

    var body: some View {
        GroupedFormRow(separated: separated) {
            Text(title, tableName: tableName)
            Spacer()
            Toggle(isOn: $isOn) { Text(title, tableName: tableName) }
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}
