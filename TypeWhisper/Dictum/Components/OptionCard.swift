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
                // 设计稿中标题行高 18.84 pt，说明行高 1.5 倍（18 pt）。
                Text(title, tableName: tableName).font(DictumTheme.Typography.section).frame(height: 18.84)
                Text(detail, tableName: tableName).font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.textSecondary)
                    .lineSpacing(3).padding(.vertical, 1.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(isSelected ? DictumTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? DictumTheme.accent : DictumTheme.separator, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
