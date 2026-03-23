import XCTest
@testable import TypeWhisper

final class AppFormatterServiceTests: XCTestCase {
    func testBundledReleaseChannelUsesInfoDictionaryValue() {
        let channel = AppConstants.bundledReleaseChannel(
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.releaseCandidate.rawValue]
        )

        XCTAssertEqual(channel, .releaseCandidate)
    }

    func testSelectedUpdateChannelUsesStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .daily)
    }

    func testSelectedUpdateChannelIgnoresInvalidStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .stable)
    }

    @MainActor
    func testMarkdownFormattingNormalizesBullets() {
        let service = AppFormatterService()

        let output = service.format(
            text: "bullet first item\n* second item",
            bundleId: "md.obsidian",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "- first item\n- second item")
    }

    @MainActor
    func testHTMLFormattingEscapesMarkup() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.apple.mail",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "<p>hello &lt;team&gt;</p>\n<ul>\n<li>launch</li>\n</ul>")
    }
}
