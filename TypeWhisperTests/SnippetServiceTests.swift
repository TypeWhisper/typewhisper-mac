import XCTest
@testable import TypeWhisper

final class SnippetServiceTests: XCTestCase {
    @MainActor
    func testSnippetsReplaceCaseInsensitiveTriggersAndTrackUsage() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = SnippetService(appSupportDirectory: appSupportDirectory)
        service.addSnippet(trigger: "sig", replacement: "Best regards", caseSensitive: false)

        let output = service.applySnippets(to: "SIG")

        XCTAssertEqual(output, "Best regards")
        XCTAssertEqual(service.enabledSnippetsCount, 1)
        XCTAssertEqual(service.snippets.first?.usageCount, 1)
    }
}
