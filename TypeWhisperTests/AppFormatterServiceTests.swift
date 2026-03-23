import XCTest
@testable import TypeWhisper

final class AppFormatterServiceTests: XCTestCase {
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
