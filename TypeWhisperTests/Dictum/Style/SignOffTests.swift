import XCTest
@testable import TypeWhisper

@MainActor
final class SignOffTests: XCTestCase {
    private func style(signOff: String?) -> ResolvedStyle {
        ResolvedStyle(formality: .formal, tone: .warm, emoji: .none,
                      signOff: signOff, extraInstructions: "", group: nil)
    }

    func testMissingSignOffIsAppendedOnItsOwnLine() {
        XCTAssertEqual(style(signOff: "小林").appendingSignOff(to: "明天见。"), "明天见。\n小林")
    }

    func testSignOffAlreadyAtTheEndStaysUnchanged() {
        let style = style(signOff: "小林")
        XCTAssertEqual(style.appendingSignOff(to: "明天见。\n小林"), "明天见。\n小林")
        XCTAssertEqual(style.appendingSignOff(to: "明天见。\n小林。"), "明天见。\n小林。")
        XCTAssertEqual(style.appendingSignOff(to: "明天见。\n小林 👋"), "明天见。\n小林 👋")
        XCTAssertEqual(style.appendingSignOff(to: "明天见。\n  小林  "), "明天见。\n  小林  ")
    }

    func testAppendingSignOffIsIdempotent() {
        let style = style(signOff: "小林")
        let once = style.appendingSignOff(to: "明天见。")
        XCTAssertEqual(style.appendingSignOff(to: once), once)
    }

    func testNoSignOffWhenStyleHasNone() {
        XCTAssertEqual(style(signOff: nil).appendingSignOff(to: "明天见。"), "明天见。")
        XCTAssertEqual(style(signOff: "  ").appendingSignOff(to: "明天见。"), "明天见。")
    }

    func testEmptyAndWhitespaceTextStaysUnchanged() {
        let style = style(signOff: "小林")
        XCTAssertEqual(style.appendingSignOff(to: ""), "")
        XCTAssertEqual(style.appendingSignOff(to: "  \n"), "  \n")
    }

    func testCodeAppStyleNeverRequestsTheGlobalSignOff() {
        let global = StyleSettings(formality: .formal, signOff: "小林")
        let resolved = ResolvedStyle.resolve(bundleID: "com.apple.dt.Xcode", browserURL: nil,
                                             global: global, apps: AppStyle.defaults)
        XCTAssertNil(resolved.requestedSignOff)
        XCTAssertEqual(resolved.appendingSignOff(to: "改完了。"), "改完了。")
        let unknown = ResolvedStyle.resolve(bundleID: "com.example.other", browserURL: nil,
                                            global: global, apps: AppStyle.defaults)
        XCTAssertEqual(unknown.appendingSignOff(to: "改完了。"), "改完了。\n小林")
    }

    func testTranslationHandlerAppendsTheMissingSignOffAboveLightLevel() async throws {
        let style = ResolvedStyle(formality: .formal, tone: .warm, emoji: .none,
                                  signOff: "小林", extraInstructions: "", group: nil)
        for (level, expected) in [(PolishLevel.standard, "I'm downstairs.\n小林"), (.rewrite, "I'm downstairs.\n小林"), (.light, "I'm downstairs.")] {
            let chain = ChainDouble(result: .success("I'm downstairs."))
            let handler = TranslationHandler.make(
                pair: .init(spoken: "zh-Hans", target: "en"), processor: chain, style: style,
                level: level, vocabulary: [],
                app: .init(appName: "Mail", bundleID: "com.apple.mail", browserURL: nil))
            let output = try await handler?("我到楼下了")
            XCTAssertEqual(output, expected, "\(level)")
        }
    }

    func testApplicationNameDropsTheAppExtension() {
        for path in ["/System/Applications/TextEdit.app", "/Applications/Xcode.app"] {
            let url = URL(fileURLWithPath: path)
            let name = AppStyle.applicationName(at: url)
            XCTAssertFalse(name.hasSuffix(".app"), path)
            XCTAssertTrue(FileManager.default.displayName(atPath: path).hasPrefix(name), path)
        }
    }
}
