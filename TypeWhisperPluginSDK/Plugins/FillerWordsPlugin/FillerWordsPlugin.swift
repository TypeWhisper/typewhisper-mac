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

        var normalizedWords = normalizedWords(from: words)
        if normalizedWords.contains(where: { languageBoundFillerWords[$0] != nil }) {
            let outputLanguage = outputLanguage(of: text, configuredLanguage: language)
            normalizedWords.removeAll { word in
                guard let fillerLanguage = languageBoundFillerWords[word] else { return false }
                return fillerLanguage != outputLanguage
            }
        }
        guard !normalizedWords.isEmpty else { return text }

        var result = removeLatinFillerWords(from: text, words: normalizedWords)
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

    /// Recognized languages below this confidence count as unknown, which
    /// keeps every language-bound filler in the text.
    private static let minimumLanguageConfidence = 0.85

    /// The base language code of the transcript: the configured dictation
    /// language if there is one, otherwise a confident text recognition.
    static func outputLanguage(of text: String, configuredLanguage: String?) -> String? {
        if let configuredLanguage = baseLanguageCode(configuredLanguage) {
            return configuredLanguage
        }

        // The ambiguous fillers themselves would skew the recognizer
        // ("Um, can you…" reads as Portuguese), so they are masked first.
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:"# + languageBoundFillerWords.keys
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|") + #")(?![\p{L}\p{N}_])"#
        let maskedText = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)

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
    /// occurrence ("I I I think" -> "I think"). Two repetitions and
    /// punctuated repeats ("no, no, no") are kept as deliberate emphasis.
    static func collapseStutters(in text: String) -> String {
        let wordBoundary = #"[\p{L}\p{N}_'’-]"#
        let pattern = #"(?i)(?<!"# + wordBoundary + #")(\p{L}+)(?:[ \t]+\1){2,}(?!"# + wordBoundary + #")"#
        return text.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
    }

    private static func removeLatinFillerWords(from text: String, words: [String]) -> String {
        let latinWords = words.filter { !$0.containsJapaneseScript }
        guard !latinWords.isEmpty else { return text }

        let escapedWords = latinWords
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}_])[,.!?]?[ \t]*(?:"# + escapedWords + #")(?![\p{L}\p{N}_])[ \t]*[,.!?]?"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        // A capitalized filler that opened a sentence hands its capital to
        // the next word, so "Um, so I think" becomes "So I think".
        var stripped = ""
        var resumeLocation = 0
        var capitalOwed = false
        for match in matches {
            let keptRange = NSRange(location: resumeLocation, length: match.range.location - resumeLocation)
            appendRestoringCapital(nsText.substring(with: keptRange), to: &stripped, capitalOwed: &capitalOwed)
            let filler = nsText.substring(with: match.range)
            if filler.first(where: \.isLetter)?.isUppercase == true, opensSentence(stripped) {
                capitalOwed = true
            }
            stripped += " "
            resumeLocation = NSMaxRange(match.range)
        }
        appendRestoringCapital(nsText.substring(from: resumeLocation), to: &stripped, capitalOwed: &capitalOwed)

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
    }

    private static func opensSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?…".contains(last)
    }

    private static func appendRestoringCapital(_ segment: String, to text: inout String, capitalOwed: inout Bool) {
        guard capitalOwed, let index = segment.firstIndex(where: { $0.isLetter || $0.isNumber }) else {
            text += segment
            return
        }
        capitalOwed = false
        text += segment[..<index]
        text += segment[index].uppercased()
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
