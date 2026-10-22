import SwiftUI

struct Sidebar: View {
    @Binding var page: DictumPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageGroup(settings: false)
            Text("Settings", tableName: "DictumShell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DictumTheme.textTertiary)
                .padding(.top, 14).padding(.bottom, 5).padding(.horizontal, 10)
            pageGroup(settings: true)
            Spacer(minLength: 12)
            SidebarStatusRow { page = .speech }
        }
        .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    private func pageGroup(settings: Bool) -> some View {
        VStack(spacing: 1) {
            ForEach(DictumPage.allCases.filter { $0.isSettings == settings }) { destination in
                Button { page = destination } label: {
                    HStack(spacing: 9) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 15)).frame(width: 16)
                            .foregroundStyle(page == destination ? DictumTheme.accent : DictumTheme.textSecondary)
                            .accessibilityHidden(true)
                        Text(destination.title).font(DictumTheme.Typography.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(page == destination ? DictumTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dictum.page.\(destination.rawValue)")
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .keyboardShortcut(destination.shortcut, modifiers: .command)
            }
        }
    }
}
