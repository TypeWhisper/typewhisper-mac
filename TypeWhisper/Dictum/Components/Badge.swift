import SwiftUI

struct Badge: View {
    let text: String
    var tint: Color = DictumTheme.accent

    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint).padding(.horizontal, 6).frame(height: 18)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
}
