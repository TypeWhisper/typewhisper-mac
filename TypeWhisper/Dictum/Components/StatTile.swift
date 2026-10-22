import SwiftUI

struct StatTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var delta: String? = nil
    var improved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(DictumTheme.Typography.stat)
                if let unit { Text(unit).font(DictumTheme.Typography.body).foregroundStyle(DictumTheme.textSecondary) }
            }
            if let delta {
                Text(delta).font(.system(size: 11.5)).foregroundStyle(improved ? DictumTheme.success : DictumTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}
