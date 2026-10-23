import SwiftUI

struct HomeHeatmap: View {
    let days: [UsageStatisticsDaySnapshot]
    @State private var hovered: Int?

    private var dates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -357 - mondayOffset, to: today)!
        return (0..<364).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    var body: some View {
        let dates = dates
        let today = Calendar.current.startOfDay(for: Date())
        let counts = Dictionary(days.map { (Calendar.current.startOfDay(for: $0.day), $0.totalWords) }, uniquingKeysWith: +)
        VStack(alignment: .trailing, spacing: 8) {
            GeometryReader { proxy in
                let pitch = max(12, min(14, (proxy.size.width - 28 - 11) / 51))
                Canvas { context, _ in
                    for index in dates.indices {
                        let date = dates[index]
                        let column = index / 7
                        let row = index % 7
                        if row == 0 && Calendar.current.component(.day, from: date) <= 7 {
                            let x = 28 + CGFloat(column) * pitch
                            let trailing = column >= 50
                            context.draw(Text(date, format: .dateTime.month(.abbreviated)).font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: trailing ? x + 11 : x, y: 5), anchor: trailing ? .trailing : .leading)
                        }
                        if column == 0 && row.isMultiple(of: 2) && row < 5 {
                            context.draw(Text(date, format: .dateTime.weekday(.narrow)).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 0, y: 25 + CGFloat(row) * pitch), anchor: .leading)
                        }
                        let rect = CGRect(x: 28 + CGFloat(column) * pitch, y: 20 + CGFloat(row) * pitch, width: 11, height: 11)
                        if date <= today {
                            context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(DictumTheme.heat[HomeMetrics.heatLevel(words: counts[date, default: 0])]))
                        }
                    }
                }
                .onContinuousHover { phase in
                    if case .active(let location) = phase {
                        let column = Int((location.x - 28) / pitch)
                        let row = Int((location.y - 20) / pitch)
                        hovered = location.x >= 28 && location.y >= 20 && (0..<52).contains(column) && (0..<7).contains(row) ? column * 7 + row : nil
                    } else { hovered = nil }
                }
            }
            .frame(height: 118)
            .help(tooltip(dates: dates, counts: counts))
            .accessibilityChildren {
                ForEach(dates, id: \.self) { date in
                    Text(date, format: .dateTime.year().month().day()).accessibilityValue(counts[date, default: 0].formatted())
                }
            }
            HStack(spacing: 4) {
                Text("Less", tableName: "DictumHome")
                ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 2.5).fill(DictumTheme.heat[level]).frame(width: 11, height: 11) }
                Text("More", tableName: "DictumHome")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func tooltip(dates: [Date], counts: [Date: Int]) -> String {
        guard let index = hovered, dates.indices.contains(index) else { return "" }
        let count = counts[dates[index], default: 0]
        guard count > 0 else { return String(localized: "No dictation", table: "DictumHome") }
        let day = dates[index].formatted(.dateTime.month().day())
        return "\(day) · \(count.formatted()) \(String(localized: "words", table: "DictumHome"))"
    }
}
