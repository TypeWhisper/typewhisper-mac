import Foundation

/// Reads the source numbers an answer cites, such as `[2]` and `[1, 3]`.
enum AskHistoryCitations {
    private static let citation = try? NSRegularExpression(pattern: #"\[\s*\d{1,3}(?:\s*,\s*\d{1,3})*\s*\]"#)

    /// The numbers of the sources an answer cites, in the order they first
    /// appear. Numbers that no source has are left out.
    static func numbers(in answer: String, sourceCount: Int) -> [Int] {
        guard sourceCount > 0 else { return [] }
        var numbers: [Int] = []
        for number in matches(in: answer).flatMap(\.numbers) where (1...sourceCount).contains(number) {
            if !numbers.contains(number) { numbers.append(number) }
        }
        return numbers
    }

    /// The answer without citations of sources that do not exist, so no
    /// number in it leads nowhere.
    static func withoutUnknownSources(_ answer: String, sourceCount: Int) -> String {
        var result = answer as NSString
        for match in matches(in: answer).reversed() {
            let valid = match.numbers.filter { sourceCount > 0 && (1...sourceCount).contains($0) }
            guard valid.count != match.numbers.count else { continue }
            var range = match.range
            var replacement = ""
            if valid.isEmpty {
                // The space before a removed citation goes with it.
                if range.location > 0, result.substring(with: NSRange(location: range.location - 1, length: 1)) == " " {
                    range = NSRange(location: range.location - 1, length: range.length + 1)
                }
            } else {
                replacement = "[" + valid.map(String.init).joined(separator: ", ") + "]"
            }
            result = result.replacingCharacters(in: range, with: replacement) as NSString
        }
        return result as String
    }

    /// The answer without any citation, for a conversation whose sources have changed.
    static func withoutCitations(_ answer: String) -> String {
        var result = answer as NSString
        for match in matches(in: answer).reversed() {
            var range = match.range
            if range.location > 0, result.substring(with: NSRange(location: range.location - 1, length: 1)) == " " {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            result = result.replacingCharacters(in: range, with: "") as NSString
        }
        return result as String
    }

    private static func matches(in answer: String) -> [(range: NSRange, numbers: [Int])] {
        let source = answer as NSString
        let whole = NSRange(location: 0, length: source.length)
        return (citation?.matches(in: answer, range: whole) ?? []).map { match in
            let numbers = source.substring(with: match.range)
                .split { !$0.isNumber }
                .compactMap { Int($0) }
            return (match.range, numbers)
        }
    }
}
