import XCTest
@testable import TypeWhisper

@MainActor
final class PolishHandlerTests: XCTestCase {
    private struct Failure: Error {}

    /// 润色模型链的测试替身：记录收到的提示词和文本，返回预设结果。
    private final class PolishDouble: PolishModelProcessing {
        var result: Result<String, Error>
        private(set) var prompts: [String] = []
        private(set) var texts: [String] = []

        init(result: Result<String, Error>) { self.result = result }

        func polish(prompt: String, text: String) async throws -> String {
            prompts.append(prompt)
            texts.append(text)
            return try result.get()
        }
    }

    private func handler(
        result: Result<String, Error>,
        signOff: String? = "小林",
        level: PolishLevel = .standard,
        onModelRun: (@Sendable () -> Void)? = nil
    ) -> (PolishHandler.Handler, PolishDouble) {
        let double = PolishDouble(result: result)
        let style = ResolvedStyle(formality: .formal, tone: .warm, emoji: .none,
                                  signOff: signOff, extraInstructions: "", group: .mail)
        let handler = PolishHandler.make(
            processor: double, level: level, style: style, vocabulary: ["dictum"],
            target: .init(appName: "Mail", bundleID: "com.apple.mail", browserURL: nil),
            onModelRun: onModelRun)
        return (handler, double)
    }

    func testSuccessAppendsTheSignOffTheModelLeftOut() async throws {
        let (handler, double) = handler(result: .success("会议改到四点。"))
        let output = try await handler("嗯，会议定在三点，不对，四点。")
        XCTAssertEqual(output, "会议改到四点。\n小林")
        XCTAssertEqual(double.texts, ["嗯，会议定在三点，不对，四点。"])
        XCTAssertTrue(double.prompts[0].contains("小林"))
    }

    func testSuccessKeepsASignOffTheModelAlreadyWrote() async throws {
        let (handler, _) = handler(result: .success("会议改到四点。\n小林"))
        let output = try await handler("会议定在四点。")
        XCTAssertEqual(output, "会议改到四点。\n小林")
    }

    func testFailureThrowsSoTheFallbackCarriesNoSignOff() async {
        let (handler, _) = handler(result: .failure(Failure()))
        do {
            _ = try await handler("原文")
            XCTFail("模型失败要抛出错误")
        } catch {}
    }

    func testModelRunCallbackFiresBeforeTheCall() async throws {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        let (handler, _) = handler(result: .success("x"), onModelRun: { flag.fired = true })
        _ = try await handler("原文")
        XCTAssertTrue(flag.fired)
    }
}
