import SwiftUI

struct Badge: View {
    let text: LocalizedStringKey
    var tint: Color? = nil
    var tableName: String = "DictumShell"

    var body: some View {
        Text(text, tableName: tableName).font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint ?? DictumTheme.textSecondary).padding(.horizontal, 6).frame(height: 18)
            .background(tint?.opacity(0.12) ?? DictumTheme.selected, in: RoundedRectangle(cornerRadius: 5))
    }
}
