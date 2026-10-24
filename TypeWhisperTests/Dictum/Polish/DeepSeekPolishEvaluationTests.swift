import XCTest
@testable import TypeWhisper

final class DeepSeekPolishEvaluationTests: XCTestCase {
    struct Sample {
        let name: String
        let text: String
        let bundleID: String
        let required: [String]
        var list = false
    }

    // 通过测试启动环境显式启用，普通单元测试不发送用户文本或产生费用。
    func testRealDeepSeekEvaluation() async throws {
        guard ProcessInfo.processInfo.environment["DICTUM_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set DICTUM_POLISH_EVAL=1 to run the real DeepSeek evaluation.")
        }
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/dictum/test-keys.env")
        let contents = try String(contentsOf: file, encoding: .utf8)
        let line = try XCTUnwrap(contents.components(separatedBy: .newlines).first { $0.hasPrefix("DEEPSEEK_API_KEY=") })
        let key = String(line.dropFirst("DEEPSEEK_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r"))
        guard !key.isEmpty else { throw XCTSkip("DeepSeek key is empty") }
        let outputURL = URL(fileURLWithPath: "/tmp/dictum-p2/eval.md")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let samples: [Sample] = [
            .init(name: "中文口头禅", text: "嗯，那个，我今天去图书馆借了两本书，呃，晚上看。", bundleID: "com.apple.Notes", required: ["图书馆", "两本", "晚上"]),
            .init(name: "中文改口", text: "嗯，会议定在三点，不对，四点，地点还是二楼。", bundleID: "com.apple.Notes", required: ["四点", "二楼"]),
            .init(name: "中文列表", text: "要买三样东西，第一苹果，第二牛奶，第三鸡蛋。", bundleID: "com.apple.Notes", required: ["苹果", "牛奶", "鸡蛋"], list: true),
            .init(name: "邮件", text: "王老师您好，嗯，周五的会议我不能参加，那个，能改到下周一吗，谢谢。", bundleID: "com.apple.mail", required: ["王老师", "周五", "下周一"]),
            .init(name: "聊天", text: "嗯，我到楼下了，你慢慢来，那个，我不着急。", bundleID: "com.tencent.xinWeChat", required: ["楼下", "不着急"]),
            .init(name: "代码笔记", text: "呃，把 userID 传给 fetchUser，那个，不要把 timeout 改成零。", bundleID: "com.apple.dt.Xcode", required: ["userID", "fetchUser", "timeout"]),
            .init(name: "English fillers", text: "Um, I went to the library and uh borrowed two books to read tonight.", bundleID: "com.apple.Notes", required: ["library", "two books", "tonight"]),
            .init(name: "English correction", text: "Uh, the meeting is at three, no, four, in room twelve.", bundleID: "com.apple.Notes", required: ["four", "twelve"]),
            .init(name: "English list", text: "We need three things, first apples, second milk, third eggs.", bundleID: "com.apple.Notes", required: ["apples", "milk", "eggs"], list: true),
            .init(name: "English question", text: "Um, can you check whether the report is ready? I don't know yet.", bundleID: "com.tinyspeck.slackmacgap", required: ["report", "?"]),
            .init(name: "混合词典", text: "嗯，dictum 的 Qwen3-ASR 已经接上了，那个，明天检查 API latency。", bundleID: "com.apple.dt.Xcode", required: ["dictum", "Qwen3-ASR", "API", "latency"]),
            .init(name: "否定与不确定", text: "呃，我不确定周三能不能发布，那个，不要承诺客户明天交付。", bundleID: "com.apple.Notes", required: ["不确定", "周三", "明天"])
        ]
        var report = "# DeepSeek 润色评估\n\n检查规则：去除语气填充词；保留全部事实、否定与疑问；不添加内容。标准和重写另检查改口与列表；轻度保留改口措辞。自动检查后须人工检查全部输出。\n\n"
        var modelsRequest = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        modelsRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
        guard (modelsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw EvaluationError.http((modelsResponse as? HTTPURLResponse)?.statusCode ?? 0) }
        let modelsObject = try JSONSerialization.jsonObject(with: modelsData) as? [String: Any]
        let ids = (modelsObject?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let model = try XCTUnwrap(["deepseek-chat", "deepseek-flash"].first { ids.contains($0) })
        report += "模型：\(model)\n\n"
        for sample in samples {
            for level in PolishLevel.allCases {
                let style = ResolvedStyle.resolve(bundleID: sample.bundleID, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults)
                let polish = PolishRequest(rawTranscript: sample.text, level: level, style: style,
                                           vocabulary: ["dictum", "Qwen3-ASR", "userID", "fetchUser", "timeout"],
                                           target: .init(appName: nil, bundleID: sample.bundleID, browserURL: nil))
                var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
                request.timeoutInterval = 120
                request.httpMethod = "POST"
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "temperature": 0.2,
                    "messages": [["role": "system", "content": polish.systemPrompt], ["role": "user", "content": TypeWhisperDictatedTextBoundary.wrap(polish.userContent)]]])
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    report += "\nHTTP \(status)，停止评估。\n"
                    try report.write(to: outputURL, atomically: true, encoding: .utf8)
                    throw EvaluationError.http(status)
                }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let choice = (object?["choices"] as? [[String: Any]])?.first
                let rawOutput = try XCTUnwrap((choice?["message"] as? [String: Any])?["content"] as? String)
                let output = TypeWhisperDictatedTextBoundary.sanitize(rawOutput, originalUserText: sample.text, fallbackToOriginalUserText: false)
                let missing = sample.required.filter { !output.localizedCaseInsensitiveContains($0) }
                let hasFillers = output.range(of: "嗯|呃|\\b(um|uh)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                let hasList = !sample.list || level == .light || output.components(separatedBy: .newlines).filter { !$0.isEmpty }.count >= 3
                let mailParagraphs = sample.bundleID != "com.apple.mail" || level == .light || output.contains("\n\n")
                let correctionResolved = level == .light ||
                    (sample.name != "中文改口" || !output.contains("三点")) &&
                    (sample.name != "English correction" || !output.localizedCaseInsensitiveContains("three"))
                let passed = missing.isEmpty && !hasFillers && hasList && mailParagraphs && correctionResolved
                report += "## \(sample.name) / \(level.rawValue) / 自动检查 \(passed ? "PASS" : "FAIL")\n\n输入：\(sample.text)\n\n输出：\n\n\(output)\n\n"
                try report.write(to: outputURL, atomically: true, encoding: .utf8)
                XCTAssertTrue(passed, "\(sample.name)/\(level.rawValue) failed; inspect eval.md")
            }
        }
    }

    enum EvaluationError: Error { case http(Int) }
}
