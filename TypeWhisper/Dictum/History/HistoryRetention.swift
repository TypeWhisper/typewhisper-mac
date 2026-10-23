import Foundation

enum HistoryRetention: Int, CaseIterable, Identifiable {
    case forever = 0
    case year = 365
    case month = 30
    case week = 7
    case day = 1
    case never = -1

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .forever: String(localized: "Forever", table: "DictumHistory")
        case .year: String(localized: "1 year", table: "DictumHistory")
        case .month: String(localized: "1 month", table: "DictumHistory")
        case .week: String(localized: "1 week", table: "DictumHistory")
        case .day: String(localized: "24 hours", table: "DictumHistory")
        case .never: String(localized: "Don't keep", table: "DictumHistory")
        }
    }

    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .forever: nil
        case .never: now
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .day: now.addingTimeInterval(-86400)
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> Self {
        if defaults.object(forKey: UserDefaultsKeys.historyEnabled) as? Bool == false { return .never }
        guard defaults.object(forKey: UserDefaultsKeys.historyRetentionDays) != nil else { return .year }
        return Self(rawValue: defaults.integer(forKey: UserDefaultsKeys.historyRetentionDays)) ?? .year
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: UserDefaultsKeys.historyRetentionDays)
        defaults.set(self != .never, forKey: UserDefaultsKeys.historyEnabled)
    }
}
