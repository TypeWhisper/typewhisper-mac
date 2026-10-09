import Foundation
import NaturalLanguage
import SwiftUI
import TypeWhisperPluginSDK

@objc(FillerWordsPlugin)
final class FillerWordsPlugin: NSObject, PostProcessorPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.filler-words"
    static let pluginName = "Filler Words"

    let processorName = "Filler Words"
    let priority = 250

    private var settingsStore: FillerWordsSettingsStore?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        settingsStore = FillerWordsSettingsStore(host: host)
    }

    func deactivate() {
        settingsStore = nil
    }

    var settingsView: AnyView? {
        guard let settingsStore else { return nil }
        return AnyView(FillerWordsSettingsView(store: settingsStore))
    }

    @MainActor
    func process(text: String, context: PostProcessingContext) async throws -> String {
        let result = Self.removeFillerWords(
            from: text,
            words: settingsStore?.words ?? Self.defaultFillerWords,
            language: context.language
        )
        guard settingsStore?.collapseStutters ?? true else { return result }
        return Self.collapseStutters(in: result)
    }

    static func removeFillerWords(from text: String, language: String? = nil) -> String {
        removeFillerWords(from: text, words: defaultFillerWords, language: language)
    }

    static func removeFillerWords(from text: String, words: [String], language: String? = nil) -> String {
        guard !text.isEmpty else { return text }

        let normalizedWords = normalizedWords(from: words)
        guard !normalizedWords.isEmpty else { return text }

        // Language recognition only runs when a language-bound filler is in
        // the text; otherwise there is nothing for it to decide.
        var languageSpans: [LanguageSpan] = []
        if normalizedWords.contains(where: { languageBoundFillerWords[$0] != nil }),
           text.range(of: languageBoundFillerPattern, options: .regularExpression) != nil {
            languageSpans = Self.languageSpans(of: text, configuredLanguage: language)
        }

        var result = removeLatinFillerWords(
            from: text,
            words: normalizedWords,
            language: language,
            languageSpans: languageSpans
        )
        result = removeJapaneseFillerWords(from: result, words: normalizedWords)

        return result
    }

    /// Fillers that are real words in other languages, such as German "um"
    /// ("at") or "eh" ("anyway") and Portuguese "um" ("a"). They are only
    /// removed when the text is known to be in the mapped language.
    static let languageBoundFillerWords: [String: String] = [
        "ah": "en",
        "eh": "en",
        "um": "en"
    ]

    private static let languageBoundFillerPattern = #"(?i)(?<![\p{L}\p{N}_])(?:"# + languageBoundFillerWords.keys
        .map(NSRegularExpression.escapedPattern(for:))
        .joined(separator: "|") + #")(?![\p{L}\p{N}_])"#

    /// Recognized languages below this confidence count as unknown, which
    /// keeps every language-bound filler in the text.
    private static let minimumLanguageConfidence = 0.85

    private struct LanguageSpan {
        let range: NSRange
        let language: String?
    }

    /// The base language code of each sentence that contains a
    /// language-bound filler. A configured dictation language covers the
    /// whole text. Otherwise a sentence takes its own confident recognition
    /// or the whole text's; if both are known and disagree, its language is
    /// unknown. So a German sentence in an English transcript keeps its "um",
    /// and so does an English-looking sentence in a German one.
    private static func languageSpans(of text: String, configuredLanguage: String?) -> [LanguageSpan] {
        if let configuredLanguage = baseLanguageCode(configuredLanguage) {
            return [LanguageSpan(range: NSRange(location: 0, length: (text as NSString).length), language: configuredLanguage)]
        }

        let textLanguage = recognizedLanguage(of: text)
        var spans: [LanguageSpan] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            guard sentence.range(of: languageBoundFillerPattern, options: .regularExpression) != nil else { return true }
            let sentenceLanguage = recognizedLanguage(of: sentence)
            let language: String? = switch (sentenceLanguage, textLanguage) {
            case let (own?, overall?) where own != overall: nil
            default: sentenceLanguage ?? textLanguage
            }
            spans.append(LanguageSpan(range: NSRange(range, in: text), language: language))
            return true
        }
        return spans
    }

    /// The base language code of `text` if the recognizer is confident.
    static func recognizedLanguage(of text: String) -> String? {
        // The ambiguous fillers themselves would skew the recognizer
        // ("Um, can you…" reads as Portuguese), so they are masked first.
        let maskedText = text.replacingOccurrences(of: languageBoundFillerPattern, with: "", options: .regularExpression)

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(maskedText)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= minimumLanguageConfidence else {
            return nil
        }
        return baseLanguageCode(hypothesis.key.rawValue)
    }

    private static func baseLanguageCode(_ code: String?) -> String? {
        guard let base = code?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { return nil }
        let normalized = base.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.isEmpty || normalized == "auto" ? nil : normalized
    }

    /// Shortens a word repeated three or more times in a row to a single
    /// occurrence ("I I I think" -> "I think", "I'm I'm I'm" -> "I'm"). Two
    /// repetitions and punctuated repeats ("no, no, no") are kept as
    /// deliberate emphasis.
    static func collapseStutters(in text: String) -> String {
        // Zero-width joiners belong to words in Persian and Indic scripts. An
        // apostrophe only extends a word between letters (`I'm`); around the
        // repeats it is a quote mark (`'well well well'`).
        // Digits count when the word has a letter ("COVID-19", not "1 1 1").
        let letter = #"[\p{L}\p{M}\p{N}\x{200C}\x{200D}]"#
        let wordCharacter = #"[\p{L}\p{M}\p{N}_\x{200C}\x{200D}-]"#
        let word = #"((?=[\p{L}\p{M}\p{N}\x{200C}\x{200D}'’-]*\p{L})"# + letter + "+(?:['’-]" + letter + "+)*)"
        let pattern = #"(?i)(?<!"# + wordCharacter + #"|"# + wordCharacter + #"['’])"# + word
            + #"(?:[ \t]+\1){2,}(?!"# + wordCharacter + #"|['’]"# + wordCharacter + #")"#
        return text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
    }

    private static func removeLatinFillerWords(
        from text: String,
        words: [String],
        language: String?,
        languageSpans: [LanguageSpan]
    ) -> String {
        let latinWords = words.filter { !$0.containsJapaneseScript }
        guard !latinWords.isEmpty else { return text }

        let escapedWords = latinWords
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}_])[,.!?]?[ \t]*("# + escapedWords + #")(?![\p{L}\p{N}_])[ \t]*[,.!?]?"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        // A language-bound filler only goes in a sentence of its language.
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).filter { match in
            let wordRange = match.range(at: 1)
            guard let fillerLanguage = languageBoundFillerWords[nsText.substring(with: wordRange).lowercased()] else {
                return true
            }
            let span = languageSpans.first { NSLocationInRange(wordRange.location, $0.range) }
            return span?.language == fillerLanguage
        }
        guard !matches.isEmpty else { return text }

        // A capitalized filler that opened a sentence hands its capital to
        // the next word, so "Um, so I think" becomes "So I think".
        // A filler attached to an opening bracket or quote leaves the next
        // word attached to it; padding such as `« Euh, bonjour »` stays.
        // The configured language picks the case mapping (Turkish i -> İ).
        let locale = language.map(Locale.init(identifier:))
        var stripped = ""
        var resumeLocation = 0
        var capitalOwed = false
        var joinsOpeningDelimiter = false
        func appendKept(_ segment: String) {
            let segment = joinsOpeningDelimiter
                ? String(segment.drop { $0 == " " || $0 == "\t" })
                : segment
            if !segment.isEmpty { joinsOpeningDelimiter = false }
            appendRestoringCapital(segment, to: &stripped, capitalOwed: &capitalOwed, locale: locale)
        }
        for match in matches {
            appendKept(nsText.substring(with: NSRange(location: resumeLocation, length: match.range.location - resumeLocation)))
            let filler = nsText.substring(with: match.range)
            // Attached means nothing, not even leading punctuation, was
            // matched before the filler word itself.
            let fillerIsAttached = match.range(at: 1).location == match.range.location
            if filler.first(where: \.isLetter)?.isUppercase == true,
               opensSentence(stripped, fillerIsAttached: fillerIsAttached) {
                capitalOwed = true
            }
            if fillerIsAttached, endsWithOpeningDelimiter(stripped, fillerIsAttached: true) {
                joinsOpeningDelimiter = true
            } else {
                stripped += " "
            }
            resumeLocation = NSMaxRange(match.range)
        }
        appendKept(nsText.substring(from: resumeLocation))

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
    }

    /// An opening bracket or quote (`He said “Um, yes”`) and a new line start
    /// a sentence; closing quotes and brackets are skipped to find the end of
    /// the previous one (`(Okay.) Um`).
    private static func opensSentence(_ text: String, fillerIsAttached: Bool) -> Bool {
        if endsWithOpeningDelimiter(text, fillerIsAttached: fillerIsAttached) { return true }
        for character in text.reversed() {
            if character.isNewline { return true }
            if character.isWhitespace || character.isQuoteOrBracket { continue }
            return ".!?…".contains(character)
        }
        return true
    }

    /// Whether `text` ends with an opening bracket or quote. Quote marks
    /// open in some locales and close in others (`»ja«`, `«oui»`), so their
    /// position decides. After whitespace or another opening delimiter
    /// (`(“`) they open; right after a letter (`„ja“ äh nein`) they close.
    /// After other punctuation such as a dash or colon they open only when
    /// the removed filler was attached: `:“Um` opens, `—” Um` closes.
    private static func endsWithOpeningDelimiter(_ text: String, fillerIsAttached: Bool) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        if last == "¿" || last == "¡" { return true }
        switch last.properties.generalCategory {
        case .openPunctuation:
            return true
        case .initialPunctuation, .finalPunctuation:
            break
        default:
            guard last == "\"" || last == "'" else { return false }
        }
        guard let beforeQuote = text.unicodeScalars.dropLast().last else { return true }
        if CharacterSet.whitespacesAndNewlines.contains(beforeQuote) { return true }
        switch beforeQuote.properties.generalCategory {
        case .openPunctuation, .initialPunctuation:
            return true
        default:
            return fillerIsAttached && !CharacterSet.alphanumerics.contains(beforeQuote)
        }
    }

    private static func appendRestoringCapital(
        _ segment: String,
        to text: inout String,
        capitalOwed: inout Bool,
        locale: Locale?
    ) {
        guard capitalOwed, let tokenStart = segment.firstIndex(where: { !$0.isWhitespace }) else {
            text += segment
            return
        }
        capitalOwed = false

        // Only an ordinary word takes the capital, optionally after opening
        // quotes or brackets. Mixed-case spellings ("iPhone", "eBay"), URLs,
        // handles and other identifiers stay as they are.
        let token = segment[tokenStart...].prefix { !$0.isWhitespace }
        guard let index = token.firstIndex(where: { !$0.isQuoteOrBracket }), token[index].isLetter else {
            text += segment
            return
        }
        let word = token[index...].prefix { $0.isLetter || "'’-".contains($0) }
        let trailing = token[word.endIndex...]
        guard !word.dropFirst().contains(where: \.isUppercase),
              trailing.allSatisfy({ ".,!?;:…".contains($0) || $0.isQuoteOrBracket }) else {
            text += segment
            return
        }
        text += segment[..<index]
        text += String(segment[index]).uppercased(with: locale)
        text += segment[segment.index(after: index)...]
    }

    private static func removeJapaneseFillerWords(from text: String, words: [String]) -> String {
        let japaneseWords = words.filter(\.containsJapaneseScript)
        guard !japaneseWords.isEmpty else { return text }

        let escapedWords = japaneseWords
            .map { word in
                let escaped = NSRegularExpression.escapedPattern(for: word)
                if word == "まあ" || word == "まぁ" {
                    return escaped + #"(?!ま[あぁ])"#
                }
                return escaped
            }
            .joined(separator: "|")
        let boundary = #"(^|[\s、。,.!?！？])"#
        let trailingSeparator = #"(?:[ \t]*[、,][ \t]*|[ \t]+)?"#
        let pattern = boundary + #"[ \t]*(?:"# + escapedWords + #")"# + trailingSeparator

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        guard stripped != text else { return text }

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
    }

    static let defaultFillerWords: [String] = [
        "ah",
        "ahh",
        "eh",
        "ehm",
        "hm",
        "hmm",
        "uh",
        "uhh",
        "um",
        "umm",
        "äh",
        "ähm",
        "えっと",
        "えーっと",
        "ええと",
        "えーと",
        "えと",
        "なんか",
        "まぁ",
        "まあ",
        "あのー",
        "あのぉ",
        "そのー",
        "そのぉ",
        "うーん",
        "うーむ"
    ]

    static func normalizedWords(from text: String) -> [String] {
        normalizedWords(from: text.split { separator in
            separator.isNewline || separator == "," || separator == ";"
        }.map(String.init))
    }

    private static func normalizedWords(from words: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for word in words {
            let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            normalized.append(cleaned)
        }

        return normalized.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
    }

    private static func normalizeWhitespaceAfterRemoval(_ text: String, preservingPrefixFrom original: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?<=[^\s]) {2,}(?=[^\s])"#,
            with: " ",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"(?m)^ +"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #" +$"#,
            with: "",
            options: .regularExpression
        )

        if original.first?.isWhitespace == true, result.first == " " {
            return result
        }

        return result.trimmingCharacters(in: .whitespaces)
    }
}

private final class FillerWordsSettingsStore: ObservableObject, @unchecked Sendable {
    private static let wordsKey = "words"
    private static let collapseStuttersKey = "collapseStutters"
    private static let defaultsVersionKey = "wordsDefaultsVersion"
    private static let currentDefaultsVersion = 3
    private static let legacyDefaultFillerWords = [
        "ah",
        "ahh",
        "hm",
        "hmm",
        "uh",
        "uhh",
        "um",
        "umm"
    ]

    private let host: HostServices

    @Published var wordsText: String {
        didSet {
            host.setUserDefault(wordsText, forKey: Self.wordsKey)
        }
    }

    @Published var collapseStutters: Bool {
        didSet {
            host.setUserDefault(collapseStutters, forKey: Self.collapseStuttersKey)
        }
    }

    init(host: HostServices) {
        self.host = host
        collapseStutters = host.userDefault(forKey: Self.collapseStuttersKey) as? Bool ?? true

        if let storedWords = host.userDefault(forKey: Self.wordsKey) as? String {
            wordsText = Self.migratedWordsTextIfNeeded(storedWords, host: host)
        } else {
            wordsText = Self.defaultWordsText
            host.setUserDefault(wordsText, forKey: Self.wordsKey)
            host.setUserDefault(Self.currentDefaultsVersion, forKey: Self.defaultsVersionKey)
        }
    }

    var words: [String] {
        FillerWordsPlugin.normalizedWords(from: wordsText)
    }

    var wordCount: Int {
        words.count
    }

    func resetToDefaults() {
        wordsText = Self.defaultWordsText
    }

    private static var defaultWordsText: String {
        FillerWordsPlugin.defaultFillerWords.joined(separator: "\n")
    }

    private static var legacyDefaultWordsText: String {
        legacyDefaultFillerWords.joined(separator: "\n")
    }

    private static func migratedWordsTextIfNeeded(_ storedWords: String, host: HostServices) -> String {
        let storedVersion = host.userDefault(forKey: defaultsVersionKey) as? Int ?? 1
        guard storedVersion < currentDefaultsVersion else { return storedWords }

        let storedNormalized = Set(FillerWordsPlugin.normalizedWords(from: storedWords))
        let legacyNormalized = Set(FillerWordsPlugin.normalizedWords(from: legacyDefaultWordsText))
        guard storedNormalized.isSuperset(of: legacyNormalized) else {
            host.setUserDefault(currentDefaultsVersion, forKey: defaultsVersionKey)
            return storedWords
        }

        let migratedWords: String
        if storedNormalized == legacyNormalized {
            migratedWords = defaultWordsText
        } else {
            let missingDefaults = FillerWordsPlugin.defaultFillerWords.filter { word in
                !storedNormalized.contains(word.lowercased())
            }
            migratedWords = storedWords + "\n" + missingDefaults.joined(separator: "\n")
        }

        host.setUserDefault(migratedWords, forKey: wordsKey)
        host.setUserDefault(currentDefaultsVersion, forKey: defaultsVersionKey)
        return migratedWords
    }
}

private extension Character {
    var isQuoteOrBracket: Bool {
        unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .initialPunctuation, .finalPunctuation, .openPunctuation, .closePunctuation:
                return true
            default:
                return scalar == "\"" || scalar == "'" || scalar == "¿" || scalar == "¡"
            }
        }
    }
}

private extension String {
    var containsJapaneseScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                return true
            default:
                return false
            }
        }
    }
}

private struct FillerWordsSettingsView: View {
    @ObservedObject var store: FillerWordsSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filler words")
                .font(.headline)

            Text("One word per line. Commas and semicolons are also accepted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("“um”, “ah” and “eh” are only removed from English text because they are real words in other languages.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $store.wordsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                )

            HStack {
                Text("\(store.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset Defaults") {
                    store.resetToDefaults()
                }
            }

            Toggle("Collapse stuttered words", isOn: $store.collapseStutters)

            Text("Shortens a word repeated three or more times in a row, like “I I I”, to a single word.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 360, minHeight: 260)
    }
}
