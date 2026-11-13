import Foundation

/// A period of the past that a question names, such as "last week".
struct HistoryPeriod: Equatable, Sendable {
    var interval: DateInterval
    /// The words that name periods, as UTF-16 ranges of the question, so a
    /// search does not look for them as keywords.
    var utf16Ranges: [Range<Int>]
}

/// Finds the period a question asks about, in English, German, French, Spanish
/// and Italian.
///
/// Every period lies in the past: "in October" is the last October and "on
/// Monday" the last Monday, today included. The first period of a question
/// counts.
struct HistoryPeriodResolver: Sendable {
    var now: Date
    var calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    /// - Parameter language: The question's language as an ISO 639 code, when
    ///   known. Some words name a period in one language only: French "hier"
    ///   is yesterday, German "hier" is "here".
    func period(in question: String, language: String? = nil) -> HistoryPeriod? {
        let tokens = Self.tokens(of: question)
        let numeric = numericDates(in: question)
        var matches: [Match] = []
        for date in numeric {
            guard let first = tokens.firstIndex(where: { $0.range.overlaps(date.range) }) else { continue }
            let end = (tokens.lastIndex(where: { $0.range.overlaps(date.range) }) ?? first) + 1
            guard !Self.isDeadline(tokens, from: first, to: end) else { continue }
            matches.append(Match(range: date.range, interval: interval(date.interval, sinceIfIntroducedAt: first, in: tokens)))
        }
        var index = 0
        while index < tokens.count {
            let range = tokens[index].range
            if numeric.contains(where: { $0.range.overlaps(range) }) {
                index += 1
                continue
            }
            func longestRule(at start: Int) -> (end: Int, interval: DateInterval, isPast: Bool)? {
                var best: (end: Int, interval: DateInterval, isPast: Bool)?
                for rule in Self.rules where rule.applies(to: language) {
                    guard let (end, captures) = Self.match(rule.elements[...], tokens, at: start, Captures()),
                          end > (best?.end ?? start),
                          // "Since 2026-11-03" is that day, not the year 2026.
                          !numeric.contains(where: {
                              $0.range.overlaps(tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound)
                          }),
                          let interval = interval(for: rule.outcome, captures) else { continue }
                    best = (end, interval, rule.outcome.isPast)
                }
                return best
            }
            var start = index
            var best = longestRule(at: index)
            // "Since November 3, 2025" is that day, not "since November".
            if let found = best, Self.sinceWords.contains(tokens[index].text), index + 1 < tokens.count,
               let longer = longestRule(at: index + 1), longer.end > found.end {
                start = index + 1
                best = longer
            }
            // "For last week" asks about last week; "for Friday" names a deadline.
            guard let best, best.isPast || !Self.isDeadline(tokens, from: start, to: best.end) else {
                index = max(best?.end ?? 0, index + 1)
                continue
            }
            matches.append(Match(
                range: range.lowerBound..<tokens[best.end - 1].range.upperBound,
                interval: interval(best.interval, sinceIfIntroducedAt: start, in: tokens)
            ))
            index = best.end
        }

        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        guard let first = matches.first(where: { $0.interval.start <= now }) else { return nil }
        return HistoryPeriod(interval: first.interval, utf16Ranges: matches.map(\.range))
    }

    // MARK: - Periods

    private struct Match {
        var range: Range<Int>
        var interval: DateInterval
    }

    private func interval(for outcome: Outcome, _ captures: Captures) -> DateInterval? {
        switch outcome {
        case .day(let offset): return unit(.day, offset)
        case .week(let offset): return unit(.weekOfYear, offset)
        case .month(let offset): return unit(.month, offset)
        case .year(let offset): return unit(.year, offset)
        case .ago:
            guard let number = captures.number, let component = captures.unit else { return nil }
            return unit(component, -number)
        case .rolling:
            guard let number = captures.number, let component = captures.unit,
                  let start = calendar.date(byAdding: component, value: -number, to: now),
                  let today = unit(.day, 0) else { return nil }
            return DateInterval(start: calendar.startOfDay(for: start), end: today.end)
        case .namedMonth(let past):
            guard let month = captures.month else { return nil }
            let current = calendar.dateComponents([.year, .month], from: now)
            guard let currentYear = current.year, let currentMonth = current.month else { return nil }
            let isThisYear = month < currentMonth || (month == currentMonth && !past)
            let year = captures.year ?? (isThisYear ? currentYear : currentYear - 1)
            return date(year: year, month: month, day: 1).flatMap { calendar.dateInterval(of: .month, for: $0) }
        case .weekday(let past):
            guard let weekday = captures.weekday else { return nil }
            var daysAgo = (calendar.component(.weekday, from: now) - weekday + 7) % 7
            if daysAgo == 0, past { daysAgo = 7 }
            return unit(.day, -daysAgo)
        case .date:
            guard let month = captures.month, let day = captures.day else { return nil }
            return dayInterval(year: captures.year, month: month, day: day)
        case .calendarYear:
            guard let year = captures.year else { return nil }
            return date(year: year, month: 1, day: 1).flatMap { calendar.dateInterval(of: .year, for: $0) }
        }
    }

    /// The day, week, month or year that lies `offset` units from now.
    private func unit(_ component: Calendar.Component, _ offset: Int) -> DateInterval? {
        calendar.date(byAdding: component, value: offset, to: now)
            .flatMap { calendar.dateInterval(of: component, for: $0) }
    }

    /// The day with this date. Without a year, the last one that is not in the future.
    private func dayInterval(year: Int?, month: Int, day: Int) -> DateInterval? {
        guard let currentYear = calendar.dateComponents([.year], from: now).year else { return nil }
        for year in year.map({ [$0] }) ?? [currentYear, currentYear - 1] {
            guard let date = date(year: year, month: month, day: day),
                  let interval = calendar.dateInterval(of: .day, for: date) else { continue }
            if interval.start <= now || year != currentYear { return interval }
        }
        return nil
    }

    /// Nil for a date that does not exist, such as February 30.
    private func date(year: Int, month: Int, day: Int) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let found = calendar.dateComponents([.year, .month, .day], from: date)
        return found.year == year && found.month == month && found.day == day ? date : nil
    }

    /// "By Friday" and "next Monday" name a date in what was said, not when it was said.
    private static func isDeadline(_ tokens: [Token], from start: Int, to end: Int) -> Bool {
        (start > 0 && deadlineWords.contains(tokens[start - 1].text))
            || (end < tokens.count && nextWords.contains(tokens[end].text))
    }

    /// "Since Monday" lasts from Monday until today.
    private func interval(
        _ interval: DateInterval, sinceIfIntroducedAt index: Int, in tokens: [Token]
    ) -> DateInterval {
        let introducers = [tokens[index].text] + (index > 0 ? [tokens[index - 1].text] : [])
        guard introducers.contains(where: Self.sinceWords.contains),
              let today = unit(.day, 0), today.end > interval.start else { return interval }
        return DateInterval(start: interval.start, end: today.end)
    }

    private static let isoDate = try? NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    /// "3.11." and "3.11.2026". The second dot keeps version numbers and amounts out.
    private static let dottedDate = try? NSRegularExpression(
        pattern: #"(?<![\d.])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(\d{4}))?(?!\d)"#
    )

    private func numericDates(in question: String) -> [Match] {
        let source = question as NSString
        let whole = NSRange(location: 0, length: source.length)
        func number(_ result: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = result.range(at: group)
            return range.location == NSNotFound ? nil : Int(source.substring(with: range))
        }
        var matches: [Match] = []
        for (expression, order) in [(Self.isoDate, [1, 2, 3]), (Self.dottedDate, [3, 2, 1])] {
            for result in expression?.matches(in: question, range: whole) ?? [] {
                guard let month = number(result, order[1]), let day = number(result, order[2]),
                      let interval = dayInterval(year: number(result, order[0]), month: month, day: day),
                      let range = Range(result.range) else { continue }
                matches.append(Match(range: range, interval: interval))
            }
        }
        return matches
    }

    // MARK: - Words

    private struct Token {
        /// Lowercased and without diacritics.
        var text: String
        var range: Range<Int>
    }

    private static func tokens(of question: String) -> [Token] {
        var tokens: [Token] = []
        var word = String.UnicodeScalarView()
        var start = 0
        var offset = 0
        func finish() {
            guard !word.isEmpty else { return }
            let text = String(word).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            tokens.append(Token(text: text, range: start..<offset))
            word = String.UnicodeScalarView()
        }
        for scalar in question.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if word.isEmpty { start = offset }
                word.append(scalar)
            } else {
                finish()
            }
            offset += scalar.utf16.count
        }
        finish()
        return tokens
    }

    private struct Captures {
        var number: Int?
        var unit: Calendar.Component?
        var month: Int?
        var weekday: Int?
        var day: Int?
        var year: Int?
    }

    private enum Outcome {
        /// The day, week, month or year this many units from now.
        case day(Int), week(Int), month(Int), year(Int)
        /// "Two weeks ago": the week that day lies in.
        case ago
        /// "The last two weeks": from then until today.
        case rolling
        /// `past` leaves the current month or day out: "last October", "last Monday".
        case namedMonth(past: Bool)
        case weekday(past: Bool)
        case date
        case calendarYear

        /// Named as past by its own words, as in "last week" or "two days ago".
        var isPast: Bool {
            switch self {
            case .day(let offset), .week(let offset), .month(let offset), .year(let offset): offset < 0
            case .ago, .rolling: true
            case .namedMonth(let past), .weekday(let past): past
            case .date, .calendarYear: false
            }
        }
    }

    private enum Element {
        case words(Set<String>, isOptional: Bool)
        case number, unit, month, weekday, day
        case year(isOptional: Bool)

        var isOptional: Bool {
            switch self {
            case .words(_, let isOptional), .year(let isOptional): return isOptional
            case .number, .unit, .month, .weekday, .day: return false
            }
        }
    }

    private struct Rule {
        let elements: [Element]
        let outcome: Outcome
        /// The only languages the rule holds in. Nil for every language.
        let languages: Set<String>?

        /// A pattern is a row of words. `a|b` is one of several words, `<n>`,
        /// `<unit>`, `<month>`, `<weekday>`, `<day>` and `<year>` stand for
        /// such a word, and a trailing `?` makes a word optional.
        init(_ pattern: String, _ outcome: Outcome, in languages: Set<String>? = nil) {
            elements = pattern.split(separator: " ").map { part in
                let isOptional = part.hasSuffix("?")
                let name = isOptional ? part.dropLast() : part
                switch name {
                case "<n>": return .number
                case "<unit>": return .unit
                case "<month>": return .month
                case "<weekday>": return .weekday
                case "<day>": return .day
                case "<year>": return .year(isOptional: isOptional)
                default: return .words(Set(name.split(separator: "|").map(String.init)), isOptional: isOptional)
                }
            }
            self.outcome = outcome
            self.languages = languages
        }

        func applies(to language: String?) -> Bool {
            guard let languages else { return true }
            return language.map(languages.contains) ?? false
        }
    }

    /// The token after the match and what the match captured.
    private static func match(
        _ elements: ArraySlice<Element>, _ tokens: [Token], at index: Int, _ captures: Captures
    ) -> (end: Int, captures: Captures)? {
        guard let element = elements.first else { return (index, captures) }
        let rest = elements.dropFirst()
        if index < tokens.count {
            let text = tokens[index].text
            var captures = captures
            let matches: Bool
            switch element {
            case .words(let words, _):
                matches = words.contains(text)
            case .number:
                captures.number = numbers[text] ?? Int(text).flatMap { (1...999).contains($0) ? $0 : nil }
                matches = captures.number != nil
            case .unit:
                captures.unit = units[text]
                matches = captures.unit != nil
            case .month:
                captures.month = months[text]
                matches = captures.month != nil
            case .weekday:
                captures.weekday = weekdays[text]
                matches = captures.weekday != nil
            case .day:
                captures.day = dayOfMonth(text)
                matches = captures.day != nil
            case .year:
                captures.year = text.count == 4 ? Int(text).flatMap { (1900...2199).contains($0) ? $0 : nil } : nil
                matches = captures.year != nil
            }
            if matches, let result = match(rest, tokens, at: index + 1, captures) { return result }
        }
        return element.isOptional ? match(rest, tokens, at: index, captures) : nil
    }

    /// "3", "3rd", "1er" and "1º".
    private static func dayOfMonth(_ text: String) -> Int? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard let day = Int(digits), (1...31).contains(day),
              ["", "st", "nd", "rd", "th", "er", "e", "º", "o"].contains(String(text.dropFirst(digits.count)))
        else { return nil }
        return day
    }

    private static let sinceWords: Set<String> = ["since", "seit", "depuis", "desde", "da", "dal", "ab"]
    private static let nextWords: Set<String> = ["prochain", "prochaine", "proximo", "proxima", "prossimo", "prossima"]
    private static let deadlineWords: Set<String> = nextWords.union([
        "for", "by", "until", "till", "before", "next", "every",
        "bis", "fur", "fuer", "zum", "nachsten", "naechsten", "nachste", "naechste", "jeden",
        "pour", "jusqu", "avant", "chaque", "para", "hasta", "antes", "cada", "per", "entro", "prima", "ogni",
    ])

    private static let rules: [Rule] = [
        Rule("today|heute|hoy|oggi", .day(0)),
        Rule("aujourd hui", .day(0)),
        Rule("yesterday|gestern|ayer|ieri", .day(-1)),
        Rule("hier", .day(-1), in: ["fr"]),
        Rule("vorgestern|anteayer|antier|avantieri", .day(-2)),
        Rule("day before yesterday", .day(-2)),
        Rule("avant hier", .day(-2)),
        Rule("antes de ayer", .day(-2)),
        Rule("altro ieri", .day(-2)),
        Rule("ieri l altro", .day(-2)),

        Rule("this week", .week(0)),
        Rule("diese|dieser woche", .week(0)),
        Rule("cette semaine", .week(0)),
        Rule("esta semana", .week(0)),
        Rule("questa settimana", .week(0)),
        Rule("last|past|previous week", .week(-1)),
        Rule("letzte|letzter|letzten|vergangene|vergangener|vergangenen|vorige|voriger|vorigen woche", .week(-1)),
        Rule("semaine derniere|passee", .week(-1)),
        Rule("semana pasada", .week(-1)),
        Rule("settimana scorsa|passata", .week(-1)),
        Rule("scorsa settimana", .week(-1)),

        Rule("this month", .month(0)),
        Rule("diesen|diesem monat", .month(0)),
        Rule("ce mois", .month(0)),
        Rule("este mes", .month(0)),
        Rule("questo mese", .month(0)),
        Rule("last|past|previous month", .month(-1)),
        Rule("letzten|letztem|vergangenen|vergangenem|vorigen|vorigem monat", .month(-1)),
        Rule("mois dernier|passe", .month(-1)),
        Rule("mes pasado", .month(-1)),
        Rule("mese scorso|passato", .month(-1)),
        Rule("scorso mese", .month(-1)),

        Rule("this year", .year(0)),
        Rule("dieses|diesem jahr", .year(0)),
        Rule("cette annee", .year(0)),
        Rule("este ano", .year(0)),
        Rule("quest|questo anno", .year(0)),
        Rule("last|past|previous year", .year(-1)),
        Rule("letztes|letztem|letzten|vergangenes|vergangenem|vergangenen|voriges|vorigem|vorigen jahr", .year(-1)),
        Rule("annee|an derniere|dernier|passee|passe", .year(-1)),
        Rule("ano pasado", .year(-1)),
        Rule("anno scorso|passato", .year(-1)),
        Rule("scorso anno", .year(-1)),

        Rule("<n> <unit> ago", .ago),
        Rule("vor <n> <unit>", .ago),
        Rule("il y a <n> <unit>", .ago),
        Rule("hace <n> <unit>", .ago),
        Rule("<n> <unit> fa", .ago),

        Rule("last|past <n> <unit>", .rolling),
        Rule("letzten|vergangenen <n> <unit>", .rolling),
        Rule("<n> derniers|dernieres <unit>", .rolling),
        Rule("derniers|dernieres <n> <unit>", .rolling),
        Rule("ultimos|ultimas <n> <unit>", .rolling),
        Rule("ultimi|ultime <n> <unit>", .rolling),

        // A month counts only next to a word that makes it a date: "may",
        // "march" and Italian "mai" are words of their own.
        Rule("in|im|en|a|nel|during|since|seit|depuis|desde|da|from|vom|von|ab|anfang|mitte|ende|early|late <month> <year>?", .namedMonth(past: false)),
        Rule("<month> de|del? <year>", .namedMonth(past: false)),
        Rule("last|past|letzten|letztem|vergangenen|scorso <month>", .namedMonth(past: true)),
        Rule("<month> dernier|pasado|scorso", .namedMonth(past: true)),
        Rule("on|am|den|vom|le|el|il|del? <day> of|de|del? <month> de|del? <year>?", .date),
        Rule("on|in? <month> <day> <year>?", .date, in: ["en"]),

        Rule("last|past|letzten|letztem|vergangenen|scorso|scorsa <weekday>", .weekday(past: true)),
        Rule("<weekday> dernier|pasado|scorso|scorsa", .weekday(past: true)),
        Rule("<weekday>", .weekday(past: false)),

        Rule("in|en|nel|del|during|since|seit|depuis|desde|from|jahr|year|ano|annee|anno <year>", .calendarYear),
    ]

    private static func table<Value>(_ rows: [(Value, String)]) -> [String: Value] {
        var table: [String: Value] = [:]
        for (value, words) in rows {
            for word in words.split(separator: " ") { table[String(word)] = value }
        }
        return table
    }

    private static let numbers: [String: Int] = table([
        (1, "one a an ein eine einem einer un une uno una"),
        (2, "two zwei deux dos due"),
        (3, "three drei trois tres tre"),
        (4, "four vier quatre cuatro quattro"),
        (5, "five funf fuenf cinq cinco cinque"),
        (6, "six sechs seis sei"),
        (7, "seven sieben sept siete sette"),
        (8, "eight acht huit ocho otto"),
        (9, "nine neun neuf nueve nove"),
        (10, "ten zehn dix diez dieci"),
        (11, "eleven elf onze once undici"),
        (12, "twelve zwolf zwoelf douze doce dodici"),
    ])

    private static let units: [String: Calendar.Component] = table([
        (.day, "day days tag tage tagen jour jours dia dias giorno giorni"),
        (.weekOfYear, "week weeks woche wochen semaine semaines semana semanas settimana settimane"),
        (.month, "month months monat monate monaten mois mes meses mese mesi"),
        (.year, "year years jahr jahre jahren an ans annee annees ano anos anno anni"),
    ])

    private static let months: [String: Int] = table([
        (1, "january januar janner jaenner janvier enero gennaio"),
        (2, "february februar fevrier febrero febbraio"),
        (3, "march marz maerz mars marzo"),
        (4, "april avril abril aprile"),
        (5, "may mai mayo maggio"),
        (6, "june juni juin junio giugno"),
        (7, "july juli juillet julio luglio"),
        (8, "august aout agosto"),
        (9, "september septembre septiembre setiembre settembre"),
        (10, "october oktober octobre octubre ottobre"),
        (11, "november novembre noviembre"),
        (12, "december dezember decembre diciembre dicembre"),
    ])

    /// By `Calendar`'s numbering, where Sunday is 1.
    private static let weekdays: [String: Int] = table([
        (1, "sunday sonntag dimanche domingo domenica"),
        (2, "monday montag lundi lunes lunedi"),
        (3, "tuesday dienstag mardi martes martedi"),
        (4, "wednesday mittwoch mercredi miercoles mercoledi"),
        (5, "thursday donnerstag jeudi jueves giovedi"),
        (6, "friday freitag vendredi viernes venerdi"),
        (7, "saturday samstag sonnabend samedi sabado sabato"),
    ])
}
