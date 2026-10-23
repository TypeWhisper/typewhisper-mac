import AppKit
import SwiftUI

/// 分段控件按设计稿绘制：浅灰底槽内放一个抬起的白色选中块，用于历史过滤和润色前后切换。
struct DictumSegmentedControl<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: LocalizedStringKey
    }

    let items: [Item]
    @Binding var selection: Value
    var large = false
    var tableName = "DictumHistory"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                Button {
                    selection = item.value
                } label: {
                    Text(item.title, tableName: tableName)
                        .font(.system(size: large ? 13 : 12))
                        .foregroundStyle(item.value == selection ? DictumTheme.textPrimary : DictumTheme.textSecondary)
                        .padding(.horizontal, large ? 14 : 11)
                        .frame(height: large ? 26 : 22)
                        .background {
                            if item.value == selection {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Self.selectedFill)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                                    }
                                    .shadow(color: Color.black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.value == selection ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(DictumTheme.inset)
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(DictumTheme.separator, lineWidth: 0.5)
                }
        }
    }

    private static var selectedFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x4A / 255, green: 0x4A / 255, blue: 0x4E / 255, alpha: 1)
                : .white
        })
    }
}

/// 历史详情和词典工具条上的普通按钮：28 高、圆角 6、白色控件底加半像素描边。
struct DictumActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(prominent ? Color.white : DictumTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? DictumTheme.accent : DictumTheme.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(prominent ? Color.clear : DictumTheme.controlBorder, lineWidth: 0.5)
                    }
                    .shadow(color: prominent ? Color.clear : DictumTheme.controlShadow, radius: 1.5, y: 1)
            }
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 历史列表和详情里的来源应用图标；找不到应用图标时用名称首字画一枚圆角色块。
struct DictumAppIcon: View {
    let bundleIdentifier: String?
    let name: String
    let size: CGFloat

    @MainActor private static var iconCache: [String: NSImage] = [:]

    private static func cachedIcon(for bundleIdentifier: String) -> NSImage? {
        if let cached = iconCache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleIdentifier] = icon
        return icon
    }

    var body: some View {
        if let icon = bundleIdentifier.flatMap({ Self.cachedIcon(for: $0) }) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
        } else {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: Self.fallbackColors, startPoint: .top, endPoint: .bottom))
                .overlay {
                    Text(monogram)
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                }
                .frame(width: size, height: size)
        }
    }

    private var radius: CGFloat { size >= 28 ? DictumTheme.Layout.iconLargeRadius : DictumTheme.Layout.iconSmallRadius }

    private var monogram: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    private static var fallbackColors: [Color] {
        let nsColors = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x50 / 255, green: 0x53 / 255, blue: 0x5C / 255, alpha: 1)
                : NSColor(srgbRed: 0xB6 / 255, green: 0xBB / 255, blue: 0xC6 / 255, alpha: 1)
        }
        return [Color(nsColor: nsColors), Color(nsColor: nsColors).opacity(0.82)]
    }
}

/// 词典表格的列布局：固定宽度列和按权重分配剩余宽度的列，间距和左右内边距与设计稿一致。
struct DictumColumnsLayout: Layout {
    struct Column {
        var fixed: CGFloat?
        var weight: CGFloat

        static func fixed(_ width: CGFloat) -> Column { Column(fixed: width, weight: 0) }
        static func flexible(_ weight: CGFloat = 1) -> Column { Column(fixed: nil, weight: weight) }
    }

    var columns: [Column]
    var spacing: CGFloat = 10
    var padding: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty, !columns.isEmpty else { return }
        let count = min(subviews.count, columns.count)
        let used = columns.prefix(count)
        let gaps = spacing * CGFloat(count - 1)
        let available = max(0, bounds.width - padding * 2 - gaps)
        let fixedTotal = used.compactMap(\.fixed).reduce(0, +)
        let flexibleCount = used.filter { $0.fixed == nil }.count
        let weightTotal = used.filter { $0.fixed == nil }.reduce(0) { $0 + $1.weight }
        let reserved = CGFloat(flexibleCount) * Self.minimumFlexibleWidth
        let fixedScale = fixedTotal > available - reserved && fixedTotal > 0
            ? max(0, available - reserved) / fixedTotal
            : 1
        let flexibleTotal = max(0, available - fixedTotal * fixedScale)
        var x = bounds.minX + padding
        for index in 0..<count {
            let column = used[index]
            let width = column.fixed.map { $0 * fixedScale }
                ?? (weightTotal > 0 ? flexibleTotal * column.weight / weightTotal : 0)
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private static let minimumFlexibleWidth: CGFloat = 40
}
