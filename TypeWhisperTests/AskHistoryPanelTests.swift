import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class AskHistoryPanelTests: XCTestCase {
    private let environment = AskHistoryTestEnvironment()
    private var defaultsSuite = "AskHistoryPanelTests-\(UUID().uuidString)"

    override func tearDown() async throws {
        environment.cleanUp()
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try await super.tearDown()
    }

    private func makeModel(hasPremium: Bool = true) throws -> AskHistoryPanelModel {
        let index = HistorySearchIndex(
            directory: try environment.makeDirectory().appendingPathComponent("index", isDirectory: true)
        )
        let session = AskHistorySession(
            index: index,
            retriever: HistoryRetriever(index: index) { $0 },
            service: try environment.makeService(providers: [])
        )
        return AskHistoryPanelModel(
            session: session,
            environment: AskHistoryPanelEnvironment(
                hasPremiumAccess: { hasPremium },
                cloudProviders: { [(id: "cloud-llm", name: "Cloud LLM")] },
                prewarm: {},
                openRecord: { _ in },
                openLanguageModelSettings: {},
                openPremium: {},
                defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
            )
        )
    }

    func testAQuestionForACloudProviderWaitsForConsentWhichIsRemembered() throws {
        let model = try makeModel()
        model.draft = "Was habe ich heute diktiert?"
        model.send()

        // Nothing is sent before the user allows the provider.
        XCTAssertEqual(model.consentProviders.map(\.name), ["Cloud LLM"])
        XCTAssertEqual(model.session.turns, [])

        model.allowCloudProviders()
        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.session.turns.map(\.question), ["Was habe ich heute diktiert?"])

        // The next question goes straight through.
        model.session.stop()
        model.send("Und gestern?")
        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.session.turns.count, 2)
    }

    func testDecliningKeepsTheQuestionAndSendsNothing() throws {
        let model = try makeModel()
        model.draft = "Was habe ich heute diktiert?"
        model.send()
        model.declineCloudProviders()

        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.draft, "Was habe ich heute diktiert?")
        XCTAssertEqual(model.session.turns, [])
    }

    func testWithoutPremiumNothingIsAsked() throws {
        let model = try makeModel(hasPremium: false)
        model.send("Was habe ich heute diktiert?")

        XCTAssertFalse(model.hasPremiumAccess)
        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.session.turns, [])
    }
}
