import XCTest
@testable import TypeWhisper

/// 翻译路径上的源码里，除默认语言对和测试之外，不能写死语言代码或语言名。
final class TranslationNoHardCodedLanguageTests: XCTestCase {
    private static let translationPathFiles = [
        "TypeWhisper/Dictum/Translation",
        "TypeWhisper/Dictum/VoiceBar/VoiceBarLanguages.swift",
        "TypeWhisper/Dictum/VoiceBar/VoiceBarLanguagePicker.swift",
        "TypeWhisper/Dictum/Pages/General/TranslationLanguagesSection.swift",
        "TypeWhisper/Dictum/Pages/General/TranslationShortcutRow.swift",
        "TypeWhisper/Dictum/Onboarding/DictumOnboardingView.swift",
        "TypeWhisper/Dictum/History/HistoryRecordFilter.swift",
        "TypeWhisper/Dictum/History/HistoryRetryController.swift",
        "TypeWhisper/Dictum/VoiceBar/VoiceBarPanel.swift",
        "TypeWhisper/Dictum/VoiceBar/VoiceBarState.swift",
        "TypeWhisper/Dictum/Pages/HistoryPage.swift",
        "TypeWhisper/Dictum/Pages/HomePage.swift",
        "TypeWhisper/Dictum/MenuBar/DictumMenuBarView.swift",
        "TypeWhisper/ViewModels/DictationViewModel.swift",
        "TypeWhisper/Services/HotkeyService.swift",
        "TypeWhisper/Services/HistoryExporter.swift",
        "TypeWhisper/Models/TranscriptionRecord.swift"
    ]
    private static let defaultsFile = "TranslationLanguageSettings.swift"
    private static let codePattern = try! NSRegularExpression(
        pattern: "\"(?:zh|en|ja|ko|fr|de|es|it|pt|ru|ar|hi|yue)(?:-[A-Za-z]{2,4})?\"")
    private static let namePattern = try! NSRegularExpression(
        pattern: "chinese|english|japanese|korean|french|german|spanish|中文|日本語|简体|繁体|英语|日语|韩语",
        options: .caseInsensitive)

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourceFiles() throws -> [URL] {
        var files: [URL] = []
        for path in Self.translationPathFiles {
            let url = repositoryRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), "\(path) 不存在")
            if isDirectory.boolValue {
                files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "swift" }
            } else {
                files.append(url)
            }
        }
        return files
    }

    /// 去掉行注释后，逐行检查字符串字面量。
    private func offenders(in file: URL, allowing allowedLine: (String) -> Bool = { _ in false }) throws -> [String] {
        let source = try String(contentsOf: file, encoding: .utf8)
        var found: [String] = []
        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.components(separatedBy: "//").first ?? rawLine
            let range = NSRange(line.startIndex..., in: line)
            guard Self.codePattern.firstMatch(in: line, range: range) != nil
                    || Self.namePattern.firstMatch(in: line, range: range) != nil,
                  !allowedLine(line) else { continue }
            found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        return found
    }

    func testTranslationPathHasNoHardCodedLanguages() throws {
        var found: [String] = []
        for file in try sourceFiles() {
            switch file.lastPathComponent {
            case Self.defaultsFile, "TranslationLanguageNames.swift":
                found += try offenders(in: file) { $0.contains("static let default") }
            case "DictumOnboardingView.swift":
                // 上手引导第三步介绍的是语音模型支持的语言，与翻译语言对无关。
                found += try offenders(in: file) { $0.contains("recognizes Chinese and English") }
            default:
                found += try offenders(in: file)
            }
        }
        XCTAssertEqual(found, [], "翻译路径不能写死语言：\n" + found.joined(separator: "\n"))
    }

    /// 提示词只含从语言代码生成的语言名；其余文字里没有语言名、CJK 文字或某种语言的口头禅示例。
    func testPromptTextContainsOnlyLanguageNamesGeneratedFromCodes() {
        let style = ResolvedStyle.resolve(bundleID: nil, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults)
        let pairs: [(String?, String)] = [("zh-Hans", "en"), ("en", "ja"), (nil, "fr"), ("ko", "de"), ("zh-Hant", "es")]
        for (spoken, target) in pairs {
            for level in [PolishLevel.light, .standard, .rewrite] {
                let request = TranslationRequest(
                    rawTranscript: "x", spokenLanguage: spoken, targetLanguage: target, level: level, style: style,
                    vocabulary: [], target: .init(appName: nil, bundleID: nil, browserURL: nil))
                var text = request.systemPrompt
                for code in [spoken, target].compactMap({ $0 }) {
                    text = text.replacingOccurrences(of: TranslationLanguageNames.promptName(for: code), with: " ")
                    text = text.replacingOccurrences(of: code, with: " ")
                }
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(Self.namePattern.firstMatch(in: text, range: range), "\(spoken ?? "auto")→\(target) \(level): 提示词含语言名")
                XCTAssertNil(Self.fillerPattern.firstMatch(in: text, range: range), "\(spoken ?? "auto")→\(target) \(level): 提示词含口头禅示例")
                XCTAssertFalse(text.unicodeScalars.contains { scalar in Self.nonLatinScalars.contains { $0.contains(scalar.value) } },"\(spoken ?? "auto")→\(target) \(level): 提示词含非拉丁文字")
            }
        }
    }

    private static let fillerPattern = try! NSRegularExpression(pattern: "\\b(um|uh|er|hmm|euh)\\b", options: .caseInsensitive)
    private static let nonLatinScalars: [ClosedRange<UInt32>] = [0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF]

    func testScannerDetectsAHardCodedLanguage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hard-coded-\(UUID().uuidString).swift")
        try "let target = \"en\"\nlet label = \"中文 → English\"\nlet fine = \"auto\" // \"ja\"\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try offenders(in: file).count, 2)
    }
}
