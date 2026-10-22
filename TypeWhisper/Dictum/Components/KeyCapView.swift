import SwiftUI

struct KeyCapView: View {
    let key: String

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(DictumTheme.windowBackground, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DictumTheme.separator, lineWidth: 0.5))
            .shadow(color: DictumTheme.separator, radius: 0, y: 1.5)
    }
}
