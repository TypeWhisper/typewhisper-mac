import SwiftUI

struct KeyCapView: View {
    let key: String
    var tableName: String = "DictumShell"

    var body: some View {
        Text(LocalizedStringKey(key), tableName: tableName)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 5).fill(DictumTheme.raised)
                    .shadow(color: DictumTheme.separatorStrong, radius: 0, y: 1.5)
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DictumTheme.separatorStrong, lineWidth: 0.5))
    }
}
