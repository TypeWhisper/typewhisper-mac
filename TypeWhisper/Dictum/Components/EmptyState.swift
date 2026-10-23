import SwiftUI

struct EmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    var tableName: String = "DictumShell"
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24))
                .foregroundStyle(DictumTheme.textTertiary).frame(width: 52, height: 52)
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            Text(title, tableName: tableName).font(DictumTheme.Typography.toolbar)
            Text(message, tableName: tableName).font(DictumTheme.Typography.body)
                .foregroundStyle(DictumTheme.textSecondary).multilineTextAlignment(.center)
            actions()
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
