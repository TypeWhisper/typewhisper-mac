import XCTest
@testable import TypeWhisper

/// 添加语言的搜索框每次输入都重新筛选候选列表，筛选耗时必须低于一帧的数量级。
final class TranslationLanguageTimingTests: XCTestCase {
    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testFilteringTheCandidateListIsFast() {
        let first = milliseconds { _ = TranslationLanguageCatalog.targetCandidates(excluding: ["en", "zh-Hans"]) }
        var samples: [Double] = []
        for query in ["", "j", "ja", "fran", "中文", "zzz"] {
            samples.append(milliseconds { _ = TranslationLanguageCatalog.targetCandidates(excluding: ["en", "zh-Hans"], matching: query) })
        }
        let slowest = samples.max() ?? 0
        print("TIMING candidates first=\(first)ms filtered-max=\(slowest)ms")
        XCTAssertLessThan(slowest, 16, "每次输入的筛选必须在一帧内完成")
    }

    func testSpokenOptionsAreFastAfterTheFirstCall() {
        _ = TranslationLanguageCatalog.spokenOptions(engineCodes: ["zh", "en", "ja"], selected: "zh-Hans")
        let repeated = milliseconds {
            _ = TranslationLanguageCatalog.spokenOptions(engineCodes: ["zh", "en", "ja", "fr", "de", "es", "ko"], selected: "zh-Hans")
        }
        print("TIMING spokenOptions repeated=\(repeated)ms")
        XCTAssertLessThan(repeated, 16)
    }
}
