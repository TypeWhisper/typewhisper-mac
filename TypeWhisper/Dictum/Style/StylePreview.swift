import Foundation
import SwiftUI

enum StylePreview {
    static var spoken: String { String(localized: "preview.spoken", table: "DictumStyle") }

    static func text(formality: StyleFormality, tone: StyleTone, emoji: StyleEmoji, signOff: String?) -> String {
        let key = "preview.\(formality.rawValue).\(tone.rawValue)"
        var text = String(localized: String.LocalizationValue(key), table: "DictumStyle")
        if formality != .formal {
            if emoji == .sometimes { text += " 🙏" }
            if emoji == .often { text += " 🙏🚀" }
        }
        if let signOff, !signOff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n" + signOff
        }
        return text
    }
}

struct StylePreviewWell: View {
    let text: String
    var minimumHeight: CGFloat = 0
    @State private var displayed = ""
    @State private var changing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(displayed.isEmpty ? text : displayed).font(.system(size: 13)).lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .frame(minHeight: minimumHeight, alignment: .topLeading)
            .background(DictumTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            .opacity(changing && !reduceMotion ? 0.25 : 1)
            .task(id: text) {
                guard !displayed.isEmpty else { displayed = text; return }
                withAnimation(.easeOut(duration: 0.12)) { changing = true }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                displayed = text
                withAnimation(.easeOut(duration: 0.12)) { changing = false }
            }
    }
}
