import NaturalLanguage

/// Counts the words of a transcript for History, Statistics, the short-dictation skip
/// and accessibility announcements.
enum WordCount {
    /// Uses linguistic segmentation instead of splitting at spaces, so languages written
    /// without spaces (Chinese, Japanese, Thai) count per word instead of as one (#1752).
    static func count(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }
}
