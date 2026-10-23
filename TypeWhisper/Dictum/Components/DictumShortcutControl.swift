import SwiftUI

struct DictumShortcutControl: View {
    let label: String
    let isRecording: Bool
    var tableName: String = "DictumShell"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if label.isEmpty {
                    Text("Add Backup Shortcut", tableName: tableName)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(DictumTheme.control, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DictumTheme.separatorStrong, lineWidth: 0.5))
                } else {
                    KeyCapView(key: label.replacingOccurrences(of: "Fn", with: "fn"), tableName: tableName)
                        .opacity(isRecording ? 0.35 : 1)
                }
                if isRecording {
                    Text("Press new shortcut", tableName: tableName)
                        .font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.accent)
                }
            }
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isRecording ? DictumTheme.accent : .clear, lineWidth: 2))
        }.buttonStyle(.plain)
    }
}
