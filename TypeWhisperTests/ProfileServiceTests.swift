import XCTest
@testable import TypeWhisper

final class ProfileServiceTests: XCTestCase {
    @MainActor
    func testProfileMatchingPrefersBundleAndURLSpecificity() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Bundle Only",
            bundleIdentifiers: ["com.apple.Safari"],
            priority: 5
        )
        service.addProfile(
            name: "URL Only",
            urlPatterns: ["docs.github.com"],
            priority: 10
        )
        service.addProfile(
            name: "Bundle + URL",
            bundleIdentifiers: ["com.apple.Safari"],
            urlPatterns: ["github.com"],
            priority: 1
        )

        let firstMatch = service.matchProfile(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(firstMatch?.name, "Bundle + URL")

        service.toggleProfile(try XCTUnwrap(firstMatch))

        let fallbackMatch = service.matchProfile(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(fallbackMatch?.name, "URL Only")
    }

    @MainActor
    func testRuleMatchDetailsExplainPriorityWinsWithinSameTier() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Docs Low",
            urlPatterns: ["docs.github.com"],
            priority: 1
        )
        service.addProfile(
            name: "Docs High",
            urlPatterns: ["docs.github.com"],
            priority: 9
        )

        let match = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )

        XCTAssertEqual(match?.profile.name, "Docs High")
        XCTAssertEqual(match?.kind, .websiteOnly)
        XCTAssertTrue(match?.wonByPriority == true)
        XCTAssertEqual(match?.matchedDomain, "docs.github.com")
        XCTAssertEqual(match?.competingProfileCount, 1)
    }

    @MainActor
    func testRuleMatchingFallsBackToGlobalProfileWhenNothingSpecificMatches() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ProfileService(appSupportDirectory: appSupportDirectory)

        service.addProfile(
            name: "Fallback Low",
            priority: 1
        )
        service.addProfile(
            name: "Fallback High",
            priority: 8
        )
        service.addProfile(
            name: "Safari Only",
            bundleIdentifiers: ["com.apple.Safari"],
            priority: 20
        )

        let fallbackMatch = service.matchRule(
            bundleIdentifier: "com.example.OtherApp",
            url: "https://example.com"
        )

        XCTAssertEqual(fallbackMatch?.profile.name, "Fallback High")
        XCTAssertEqual(fallbackMatch?.kind, .globalFallback)
        XCTAssertTrue(fallbackMatch?.wonByPriority == true)
        XCTAssertEqual(fallbackMatch?.competingProfileCount, 1)

        let specificMatch = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://example.com"
        )

        XCTAssertEqual(specificMatch?.profile.name, "Safari Only")
        XCTAssertEqual(specificMatch?.kind, .appOnly)
    }
}
