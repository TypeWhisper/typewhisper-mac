import SwiftUI

struct Banner<Actions: View>: View {
    let text: LocalizedStringKey
    let symbol: String
    var tint: Color = DictumTheme.warning
    var tableName: String = "DictumShell"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text, tableName: tableName).font(.system(size: 12.5))
            Spacer(minLength: 0)
            actions().controlSize(.small)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}
