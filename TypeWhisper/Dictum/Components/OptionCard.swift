import SwiftUI

struct OptionCard: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isSelected: Bool
    var tableName: String = "DictumShell"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title, tableName: tableName).font(DictumTheme.Typography.section)
                Text(detail, tableName: tableName).font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(isSelected ? DictumTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? DictumTheme.accent : DictumTheme.separator, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
