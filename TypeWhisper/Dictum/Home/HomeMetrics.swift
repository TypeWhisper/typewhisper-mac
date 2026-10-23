import Foundation

enum HomeMetrics {
    static func recentDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday", table: "DictumHome") }
        return date.formatted(.dateTime.month().day())
    }
    static func streaks(_ days: [UsageStatisticsDaySnapshot], today: Date = Date(), calendar: Calendar = .current) -> (current: Int, longest: Int) {
        let active = Set(days.filter { $0.transcriptionCount > 0 }.map { calendar.startOfDay(for: $0.day) })
        var longest = 0
        var run = 0
        var previous: Date?
        for day in active.sorted() {
            run = previous.flatMap { calendar.dateComponents([.day], from: $0, to: day).day } == 1 ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        var cursor = calendar.startOfDay(for: today)
        if !active.contains(cursor) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        var current = 0
        while active.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    static func heatLevel(words: Int) -> Int {
        switch words { case ...0: 0; case 1..<250: 1; case 250..<600: 2; case 600..<1100: 3; default: 4 }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return String(localized: "\(minutes) min", table: "DictumHome") }
        if minutes >= 6000 { return String(localized: "\(minutes / 60) h", table: "DictumHome") }
        return String(localized: "\(minutes / 60) h \(minutes % 60) min", table: "DictumHome")
    }

    static func delta(_ current: Double, _ previous: Double) -> String {
        guard previous > 0 else { return "—" }
        let change = (current - previous) / previous
        if abs(change) < 0.02 { return String(localized: "Same as last period", table: "DictumHome") }
        return "\(change > 0 ? "↑" : "↓") \(abs(change).formatted(.percent.precision(.fractionLength(0))))"
    }
}
