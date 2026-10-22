import SwiftUI

struct DictumShortcutControl: View {
    let label: String
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if label.isEmpty {
                    Text("Add Backup Shortcut", tableName: "DictumShell")
                        .foregroundStyle(DictumTheme.accent)
                } else {
                    KeyCapView(key: label.replacingOccurrences(of: "Fn", with: "fn"))
                        .opacity(isRecording ? 0.35 : 1)
                }
                if isRecording {
                    Text("Press new shortcut", tableName: "DictumShell")
                        .font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.accent)
                }
            }
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isRecording ? DictumTheme.accent : .clear, lineWidth: 2))
        }.buttonStyle(.plain)
    }
}
