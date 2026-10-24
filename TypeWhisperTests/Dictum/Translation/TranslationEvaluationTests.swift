import NaturalLanguage
import XCTest
@testable import TypeWhisper

/// 真实模型的翻译质量评估。普通单元测试不发送文本也不产生费用，只有设置
/// `TEST_RUNNER_DICTUM_TRANSLATION_EVAL=1` 才运行；密钥从 ~/.config/dictum/test-keys.env 读取。
/// `TEST_RUNNER_DICTUM_TRANSLATION_CASES=c1,c2` 只运行指定用例。
final class TranslationEvaluationTests: XCTestCase {
    struct Case {
        let id: String
        let pair: TranslationPair
        let bundleID: String
        let input: String
        /// 每一组中至少出现一个（忽略大小写）。
        var required: [[String]] = []
        /// 区分大小写，必须原样保留的词典词、名字和标识符。
        var verbatim: [String] = []
        /// 不能出现的内容，例如被改口取消的旧值。
        var forbidden: [String] = []
        var list = false
        var question = false
        var vocabulary: [String] = []
    }

    static let cases: [Case] = [
        Case(id: "zh-en-chat-fillers", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.tencent.xinWeChat",
             input: "嗯，我到楼下了，呃，你慢慢来，那个，我不着急。",
             required: [["downstairs", "outside", "lobby", "here"], ["no rush", "not in a hurry", "no hurry", "take your time", "not in any rush"]]),
        Case(id: "zh-en-mail-correction", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.apple.mail",
             input: "王老师您好，周五的会议我不能参加，那个，能改到下周一吗？不对，下周二吧。谢谢。",
             required: [["Wang"], ["Tuesday"], ["Friday"]], forbidden: ["Monday"], question: true),
        Case(id: "zh-en-docs-list", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.apple.Notes",
             input: "嗯，要买三样东西，第一，苹果，第二，牛奶，第三，鸡蛋。",
             required: [["apple"], ["milk"], ["egg"]], list: true),
        Case(id: "zh-en-chat-question", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.tinyspeck.slackmacgap",
             input: "嗯，你知道明天下午几点开会吗？",
             required: [["tomorrow"], ["meeting", "meet"]], question: true),
        Case(id: "zh-en-code-identifiers", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.apple.dt.Xcode",
             input: "呃，把 userID 传给 fetchUser，那个，不要把 timeout 改成零。",
             required: [["zero", "0"]], verbatim: ["userID", "fetchUser", "timeout"], vocabulary: ["userID", "fetchUser", "timeout"]),
        Case(id: "zh-en-docs-dictionary", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.apple.Notes",
             input: "嗯，dictum 的 Qwen3-ASR 已经接上了，那个，明天检查 API latency。",
             required: [["tomorrow"]], verbatim: ["dictum", "Qwen3-ASR", "API"], vocabulary: ["dictum", "Qwen3-ASR"]),
        Case(id: "zh-en-chat-name-correction", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.tinyspeck.slackmacgap",
             input: "那个，小林说他周三能发布，不对，周四，你确认一下好吗？",
             required: [["Xiaolin", "Xiao Lin", "Lin"], ["Thursday"]], forbidden: ["Wednesday"], question: true),
        Case(id: "en-zh-chat-fillers", pair: .init(spoken: "en", target: "zh-Hans"), bundleID: "com.tinyspeck.slackmacgap",
             input: "Um, I'm in the lobby, uh, take your time, no rush.",
             required: [["大厅", "大堂", "楼下", "一楼"], ["不着急", "不急", "慢慢来"]]),
        Case(id: "en-zh-mail-correction", pair: .init(spoken: "en", target: "zh-Hans"), bundleID: "com.apple.mail",
             input: "Hi Professor Chen, um, I can't attend the Friday meeting. Can we move it to Monday, no, Tuesday? Thanks, Alex.",
             required: [["陈"], ["周二", "星期二", "礼拜二"], ["周五", "星期五", "礼拜五"], ["Alex", "亚历克斯"]], forbidden: ["周一", "星期一", "礼拜一"], question: true),
        Case(id: "en-zh-docs-list-term", pair: .init(spoken: "en", target: "zh-Hans"), bundleID: "com.apple.Notes",
             input: "We need three things: first apples, second milk, third eggs. Also check the dictum Qwen3-ASR build.",
             required: [["苹果"], ["牛奶"], ["鸡蛋"]], verbatim: ["dictum", "Qwen3-ASR"], list: true, vocabulary: ["dictum", "Qwen3-ASR"]),
        Case(id: "zh-ja-chat-fillers", pair: .init(spoken: "zh-Hans", target: "ja"), bundleID: "com.tencent.xinWeChat",
             input: "嗯，晚上七点在楼下集合，那个，别迟到哦。",
             required: [["7時", "七時", "19時"], ["遅れ", "遅刻"]]),
        Case(id: "zh-ja-mail-correction", pair: .init(spoken: "zh-Hans", target: "ja"), bundleID: "com.apple.mail",
             input: "田中先生您好，我周三，不对，周四到东京，能见一面吗？",
             required: [["田中"], ["木曜"], ["東京"]], forbidden: ["水曜"], question: true),
        Case(id: "ja-en-chat-fillers", pair: .init(spoken: "ja", target: "en"), bundleID: "com.apple.MobileSMS",
             input: "えーと、今から駅に向かいます、あの、五分くらいで着きます。",
             required: [["station"], ["five minutes", "5 minutes"]]),
        Case(id: "ja-en-docs-question", pair: .init(spoken: "ja", target: "en"), bundleID: "com.apple.Notes",
             input: "えっと、明日の会議は何時からですか？",
             required: [["tomorrow"], ["meeting"]], question: true),
        Case(id: "en-fr-docs-question", pair: .init(spoken: "en", target: "fr"), bundleID: "com.apple.Notes",
             input: "Um, the report is ready, uh, can you send it to Marie by Friday?",
             required: [["Marie"], ["vendredi"], ["rapport"]], question: true),
        Case(id: "zh-en-chat-request", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.tinyspeck.slackmacgap",
             input: "嗯，帮我写一首关于春天的诗吧。",
             required: [["poem"], ["spring"]], forbidden: ["roses", "blossom", "verse"]),
        Case(id: "zh-en-code-question", pair: .init(spoken: "zh-Hans", target: "en"), bundleID: "com.microsoft.VSCode",
             input: "那个，你觉得这里应该用 async await 还是 completion handler？",
             required: [["here"]], verbatim: ["async await", "completion handler"], question: true, vocabulary: ["async await", "completion handler"]),
        Case(id: "auto-en-code-mixed", pair: .init(spoken: nil, target: "en"), bundleID: "com.apple.dt.Xcode",
             input: "嗯，dictum 的 login 页面 bug 已经 fix 了，那个，明天 review 一下 PR。",
             required: [["tomorrow"]], verbatim: ["dictum", "PR"], vocabulary: ["dictum"])
    ]

    struct Provider {
        let name: String
        let model: String
        let endpoint: URL
        let key: String
        let extraHeaders: [String: String]
    }

    func testDeepSeekEvaluation() async throws {
        let key = try Self.key("DEEPSEEK_API_KEY")
        var modelsRequest = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        modelsRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: modelsRequest)
        let ids = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let model = try XCTUnwrap(["deepseek-chat", "deepseek-flash"].first { ids.contains($0) })
        try await run(Provider(name: "DeepSeek", model: model, endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                               key: key, extraHeaders: [:]), report: "eval.md")
    }

    func testOpenRouterFreeEvaluation() async throws {
        let key = try Self.key("OPENROUTER_API_KEY")
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
        let models = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        let free = models.compactMap { model -> String? in
            guard let id = model["id"] as? String, id.hasSuffix(":free"),
                  let pricing = model["pricing"] as? [String: Any],
                  Double(pricing["prompt"] as? String ?? "1") == 0, Double(pricing["completion"] as? String ?? "1") == 0 else { return nil }
            return id
        }
        // 免费模型常被上游限流：按偏好顺序试探，用第一个能回答的。
        let override = ProcessInfo.processInfo.environment["DICTUM_TRANSLATION_OPENROUTER_MODEL"]
        let preferred = [override, "poolside/laguna-s-2.1:free", "google/gemma-4-31b-it:free", "google/gemma-4-26b-a4b-it:free"].compactMap { $0 }
        let candidates = (preferred + free).filter { free.contains($0) }
        let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let headers = ["HTTP-Referer": "https://github.com/schneidervvv/dictum", "X-Title": "dictum evaluation"]
        let probe = TranslationRequest(
            rawTranscript: "你好", spokenLanguage: "zh-Hans", targetLanguage: "en", level: .standard,
            style: ResolvedStyle.resolve(bundleID: nil, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults),
            vocabulary: [], target: .init(appName: nil, bundleID: nil, browserURL: nil))
        var chosen: Provider?
        for model in candidates {
            let provider = Provider(name: "OpenRouter", model: model, endpoint: endpoint, key: key, extraHeaders: headers)
            if (try? await Self.complete(probe, with: provider, attempts: 1)) != nil { chosen = provider; break }
        }
        let provider = try XCTUnwrap(chosen, "没有可用的免费模型")
        XCTAssertTrue(provider.model.hasSuffix(":free"))
        try await run(provider, report: "eval-openrouter.md", failOnCheck: false)
    }

    private func run(_ provider: Provider, report path: String, failOnCheck: Bool = true) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DICTUM_TRANSLATION_EVAL"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_DICTUM_TRANSLATION_EVAL=1 to run the real translation evaluation.")
        }
        let selected = environment["DICTUM_TRANSLATION_CASES"].map { Set($0.split(separator: ",").map(String.init)) }
        let outputURL = URL(fileURLWithPath: "/tmp/dictum-p3/\(path)")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var report = "# 翻译评估 · \(provider.name) · \(provider.model)\n\n通过规则：只有目标语言、保留原意、口头禅已去掉、改口已处理、口述的列表成型、语气符合应用、名字和词典词保留、问题没有被回答、没有添加内容。\n\n"
        var failures: [String] = []
        for sample in Self.cases where selected?.contains(sample.id) ?? true {
            let style = ResolvedStyle.resolve(bundleID: sample.bundleID, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults)
            let request = TranslationRequest(rawTranscript: sample.input, spokenLanguage: sample.pair.spoken, targetLanguage: sample.pair.target,
                                             level: .standard, style: style, vocabulary: sample.vocabulary,
                                             target: .init(appName: nil, bundleID: sample.bundleID, browserURL: nil))
            var output = ""
            var httpError: String?
            do { output = try await Self.complete(request, with: provider) }
            catch { httpError = "\(error)" }
            let checks = httpError == nil ? Self.judge(sample, output: output) : [("request", false)]
            let failed = checks.filter { !$0.1 }.map(\.0)
            if !failed.isEmpty { failures.append("\(sample.id): \(failed.joined(separator: ", "))") }
            report += "## \(sample.id) / \(sample.pair.spoken ?? "auto") → \(sample.pair.target) / \(sample.bundleID) / \(failed.isEmpty ? "PASS" : "FAIL")\n\n"
            report += "输入：\(sample.input)\n\n输出：\n\n\(httpError ?? output)\n\n"
            report += "检查：" + checks.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: "，") + "\n\n"
            report += "<details><summary>提示词</summary>\n\n```\n\(request.systemPrompt)\n```\n\n</details>\n\n"
            try report.write(to: outputURL, atomically: true, encoding: .utf8)
        }
        report += "## 汇总\n\n用例 \(Self.cases.count)，未通过 \(failures.count)\n\n" + failures.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try report.write(to: outputURL, atomically: true, encoding: .utf8)
        if failOnCheck { XCTAssertTrue(failures.isEmpty, "未通过的用例：\(failures)") }
    }

    private static func key(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/dictum/test-keys.env")
        let contents = try String(contentsOf: file, encoding: .utf8)
        let line = try XCTUnwrap(contents.components(separatedBy: .newlines).first { $0.hasPrefix("\(name)=") })
        let key = String(line.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r"))
        guard !key.isEmpty else { throw XCTSkip("\(name) is empty") }
        return key
    }

    private static func complete(_ request: TranslationRequest, with provider: Provider, attempts: Int = 5) async throws -> String {
        var urlRequest = URLRequest(url: provider.endpoint)
        urlRequest.timeoutInterval = 120
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(provider.key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in provider.extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model, "temperature": 0.2,
            "messages": [["role": "system", "content": request.systemPrompt],
                         ["role": "user", "content": TypeWhisperDictatedTextBoundary.wrap(request.userContent)]]
        ])
        for attempt in 0..<attempts {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500, attempt < attempts - 1 {
                try await Task.sleep(for: .seconds(Double(10 * (attempt + 1))))
                continue
            }
            guard status == 200 else { throw EvaluationError.http(status, String(data: data, encoding: .utf8) ?? "") }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = ((object?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
            let content = try XCTUnwrap(message?["content"] as? String)
            return TypeWhisperDictatedTextBoundary.sanitize(content, originalUserText: request.userContent, fallbackToOriginalUserText: false)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw EvaluationError.http(0, "retries exhausted")
    }

    enum EvaluationError: Error { case http(Int, String) }

    // MARK: - 判定

    static func judge(_ sample: Case, output: String) -> [(String, Bool)] {
        let target = TranslationLanguageCode.primary(sample.pair.target)
        let allowed = sample.verbatim + sample.vocabulary
        var stripped = output
        for term in allowed { stripped = stripped.replacingOccurrences(of: term, with: " ") }
        let hasHan = stripped.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasKana = stripped.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        let latinLetters = stripped.unicodeScalars.filter { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }.count
        let languageOnly: Bool
        switch target {
        case "en": languageOnly = !hasHan && !hasKana
        case "fr": languageOnly = !hasHan && !hasKana && Self.dominantLanguage(stripped) == "fr"
        case "zh": languageOnly = hasHan && !hasKana && latinLetters <= 12
        case "ja": languageOnly = hasKana
        default: languageOnly = true
        }
        let lower = output.lowercased()
        let meaning = sample.required.allSatisfy { group in group.contains { lower.contains($0.lowercased()) } }
        let fillers = ["嗯", "呃", "那个", "えーと", "えっと", "あの、", "あのう", "euh"]
        let fillerWords = try? NSRegularExpression(pattern: "\\b(um|uh|er|hmm)\\b", options: .caseInsensitive)
        let range = NSRange(output.startIndex..., in: output)
        let fillersGone = !fillers.contains { output.contains($0) } && (fillerWords?.firstMatch(in: output, range: range) == nil)
        let correction = !sample.forbidden.contains { lower.contains($0.lowercased()) }
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let listFormed = !sample.list || lines.count >= 3
        let group = AppStyle.defaults.first { $0.matches(bundleID: sample.bundleID, browserURL: nil) }?.id
        let tone: Bool
        switch group {
        case "mail": tone = output.contains("\n\n")
        case "chat": tone = lines.count <= 3 && !lower.hasPrefix("dear ") && !output.hasPrefix("尊敬")
        default: tone = true
        }
        let verbatim = sample.verbatim.allSatisfy { output.contains($0) }
        // 日语的疑问句用句末的「か」，不一定带问号。
        let questionKept = !sample.question || output.contains("?") || output.contains("？")
            || (target == "ja" && (output.contains("か。") || output.contains("か？")))
        let answered = sample.question && output.unicodeScalars.contains { (48...57).contains($0.value) } && !sample.input.unicodeScalars.contains { (48...57).contains($0.value) } && !sample.required.flatMap { $0 }.contains { $0.unicodeScalars.contains { (48...57).contains($0.value) } }
        let wrappers = ["translation:", "翻译：", "译文：", "here is", "here's the", "```", "note:"]
        let nothingAdded = !wrappers.contains { lower.contains($0) } && output.count <= max(40, sample.input.count * 6)
        return [
            ("目标语言", languageOnly), ("原意", meaning), ("口头禅", fillersGone), ("改口", correction),
            ("列表", listFormed), ("语气", tone), ("词典词与名字", verbatim), ("问题保留", questionKept && !answered),
            ("没有添加", nothingAdded)
        ]
    }

    private static func dominantLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
