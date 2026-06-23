import Foundation
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
        Self.removeFillerWords(from: text, words: settingsStore?.words ?? Self.defaultFillerWords)
    }

    static func removeFillerWords(from text: String) -> String {
        removeFillerWords(from: text, words: defaultFillerWords)
    }

    static func removeFillerWords(from text: String, words: [String]) -> String {
        guard !text.isEmpty else { return text }

        let normalizedWords = normalizedWords(from: words)
        guard !normalizedWords.isEmpty else { return text }

        var result = removeLatinFillerWords(from: text, words: normalizedWords)
        result = removeJapaneseFillerWords(from: result, words: normalizedWords)

        return result
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

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        guard stripped != text else { return text }

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
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

    init(host: HostServices) {
        self.host = host

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
        }
        .padding()
        .frame(minWidth: 360, minHeight: 260)
    }
}
