import SwiftUI
import os

struct SidebarStatusRow: View {
    let action: () -> Void
    @State private var status = SidebarStatus.current()
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SidebarStatus")

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
            logger.notice("Sidebar speech status=\(String(describing: status), privacy: .public)")
            while !Task.isCancelled {
                let current = SidebarStatus.current()
                if status != current {
                    logger.notice("Sidebar speech status=\(String(describing: current), privacy: .public)")
                    status = current
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
}
