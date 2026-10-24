import XCTest

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
        "TypeWhisper/Dictum/History/HistoryRetryController.swift"
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

    func testScannerDetectsAHardCodedLanguage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hard-coded-\(UUID().uuidString).swift")
        try "let target = \"en\"\nlet label = \"中文 → English\"\nlet fine = \"auto\" // \"ja\"\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try offenders(in: file).count, 2)
    }
}
