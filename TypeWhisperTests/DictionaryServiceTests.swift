import XCTest
@testable import TypeWhisper

final class DictionaryServiceTests: XCTestCase {
    @MainActor
    func testDictionaryTermsCorrectionsAndLearning() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        service.addEntry(type: .term, original: "TypeWhisper")
        service.addEntry(type: .term, original: "typewhisper")
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        XCTAssertEqual(service.termsCount, 1)
        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.getTermsForPrompt(), "TypeWhisper")

        let corrected = service.applyCorrections(to: "teh TypeWhisper")
        XCTAssertEqual(corrected, "the TypeWhisper")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        service.learnCorrection(original: "langauge", replacement: "language")
        XCTAssertEqual(service.correctionsCount, 2)
    }
}
