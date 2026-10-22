import SwiftUI

struct SidebarStatusRow: View {
    let action: () -> Void
    @State private var status: SidebarStatus = .noModel

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(status.titleKey, tableName: "DictumShell")
                    .font(DictumTheme.Typography.secondary)
                Spacer(minLength: 0)
                if let caption = status.caption {
                    Text(caption).font(DictumTheme.Typography.caption).foregroundStyle(DictumTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dictum.sidebar.status")
        .task {
            while !Task.isCancelled {
                status = SidebarStatus.current()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
}
