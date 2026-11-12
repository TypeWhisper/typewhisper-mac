import Foundation

/// Builds full-text queries for History's search index.
///
/// Only the letters and digits of a question reach a query, every word in
/// quotes. FTS5 operators in a question, such as `NEAR`, `NOT`, `-` and `"`,
/// therefore have no effect.
enum HistoryFullTextQuery {
    /// From this length on, a word also finds the words that start with it.
    static let prefixLength = 4
    /// A query has at most this many words, however long the question is.
    static let maximumWords = 32

    /// The words of a text as the index splits them, lowercased.
    static func words(in text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The other spelling of a German word: "mueller" for "müller", "strasse"
    /// for "straße", and back. The index folds "ü" to "u", which "ue" does not match.
    static func variant(of word: String) -> String? {
        var variant = word
        let pairs = [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")]
        if pairs.contains(where: { word.contains($0.0) }) {
            for (letter, spelling) in pairs { variant = variant.replacingOccurrences(of: letter, with: spelling) }
        } else {
            for (letter, spelling) in pairs { variant = variant.replacingOccurrences(of: spelling, with: letter) }
        }
        return variant == word ? nil : variant
    }

    /// The query for passages or titles that hold any of the words or names.
    /// A name is searched as it is written, several words as one phrase. Nil
    /// when there is nothing to search for.
    static func expression(words: [String], names: [String] = []) -> String? {
        var terms: [String] = []
        for word in words.flatMap(Self.words(in:)).prefix(maximumWords) {
            for form in [word, variant(of: word)].compactMap({ $0 }) {
                terms.append("\"\(form)\"" + (form.count >= prefixLength ? "*" : ""))
            }
        }
        for name in names.prefix(maximumWords) {
            let phrase = Self.words(in: name).joined(separator: " ")
            guard !phrase.isEmpty else { continue }
            for form in [phrase, variant(of: phrase)].compactMap({ $0 }) {
                terms.append("\"\(form)\"")
            }
        }
        var seen = Set<String>()
        terms = terms.filter { seen.insert($0).inserted }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }
}
