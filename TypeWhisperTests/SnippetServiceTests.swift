import XCTest
@testable import TypeWhisper

final class SnippetServiceTests: XCTestCase {
    @MainActor
    func testTriggersDoNotMatchInsideWords() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "sig", replacement: "Best regards")

        let input = "design signal SIGnature 1sig sig2 _sig sig_ äSIG sigé sig\u{0301} 中文sig"
        XCTAssertEqual(service.applySnippets(to: input, deferUsageCountSave: true), input)
        XCTAssertEqual(service.snippets.first?.usageCount, 0)
        service.saveDeferredUsageCounts()
        XCTAssertEqual(SnippetService(appSupportDirectory: directory).snippets.first?.usageCount, 0)
    }

    @MainActor
    func testStandaloneTriggersMatchAtTextEdgesWhitespaceAndPunctuation() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "btw", replacement: "by the way")

        XCTAssertEqual(
            service.applySnippets(to: "btw, (BTW)!\nbtw\t🙂btw🙂 btw"),
            "by the way, (by the way)!\nby the way\t🙂by the way🙂 by the way"
        )
        XCTAssertEqual(service.snippets.first?.usageCount, 1)
    }

    @MainActor
    func testCaseSensitiveTriggersStillRequireWordBoundaries() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "SIG", replacement: "Best regards", caseSensitive: true)

        XCTAssertEqual(
            service.applySnippets(to: "DESIGN SIGnature sig SIG."),
            "DESIGN SIGnature sig Best regards."
        )
        XCTAssertEqual(service.snippets.first?.usageCount, 1)
    }

    @MainActor
    func testMultiwordTriggersRequireBoundariesAroundTheWholePhrase() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "my sig", replacement: "Best regards")

        XCTAssertEqual(
            service.applySnippets(to: "amy sig; my signal; (MY SIG)"),
            "amy sig; my signal; (Best regards)"
        )
    }

    @MainActor
    func testSymbolTriggersAreLiteralAndWorkAtTextEdges() throws {
        for trigger in ["/sig", "c++", "[sig]", ".*"] {
            let directory = try TestSupport.makeTemporaryDirectory()
            defer { TestSupport.remove(directory) }
            let service = SnippetService(appSupportDirectory: directory)
            service.addSnippet(trigger: trigger, replacement: "expanded")

            XCTAssertEqual(service.applySnippets(to: trigger), "expanded", trigger)
            XCTAssertEqual(service.applySnippets(to: "(\(trigger))"), "(expanded)", trigger)
            let embedded = "a\(trigger) \(trigger)b"
            XCTAssertEqual(service.applySnippets(to: embedded), embedded, trigger)
            XCTAssertEqual(service.snippets.first?.usageCount, 2, trigger)
        }
    }

    @MainActor
    func testReplacementPreservesDollarSignsBackslashesAndPlaceholders() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "sig", replacement: #"$0 $1 C:\notes {year}"#)
        let year = Calendar.current.component(.year, from: Date())

        XCTAssertEqual(service.applySnippets(to: "🙂sig sig"), "🙂$0 $1 C:\\notes \(year) $0 $1 C:\\notes \(year)")
    }

    @MainActor
    func testEmptyAndDisabledTriggersDoNotMatchOrCountUsage() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = SnippetService(appSupportDirectory: directory)
        service.addSnippet(trigger: "", replacement: "empty")
        service.addSnippet(trigger: "sig", replacement: "Best regards")
        service.toggleSnippet(try XCTUnwrap(service.snippets.first { $0.trigger == "sig" }))

        XCTAssertEqual(service.applySnippets(to: "sig"), "sig")
        XCTAssertEqual(service.applySnippets(to: ""), "")
        XCTAssertTrue(service.snippets.allSatisfy { $0.usageCount == 0 })
    }

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

    @MainActor
    func testDeferredUsageCountsAreSavedOnlyWhenRequested() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = SnippetService(appSupportDirectory: appSupportDirectory)
        service.addSnippet(trigger: "sig", replacement: "Best regards", caseSensitive: false)

        XCTAssertEqual(service.applySnippets(to: "sig", deferUsageCountSave: true), "Best regards")
        XCTAssertEqual(service.applySnippets(to: "sig", deferUsageCountSave: true), "Best regards")
        XCTAssertEqual(service.snippets.first?.usageCount, 2)
        XCTAssertEqual(SnippetService(appSupportDirectory: appSupportDirectory).snippets.first?.usageCount, 0)

        service.saveDeferredUsageCounts()

        XCTAssertEqual(SnippetService(appSupportDirectory: appSupportDirectory).snippets.first?.usageCount, 2)
    }
}
