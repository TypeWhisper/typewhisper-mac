import Combine
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

    private var cloudProviders = [(id: "cloud-llm", name: "Cloud LLM")]
    private let accessChanges = PassthroughSubject<Void, Never>()
    private var hasPremium = true
    private var isAllowedByPolicy = true

    private func makeModel(hasPremium: Bool = true) throws -> AskHistoryPanelModel {
        self.hasPremium = hasPremium
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
                hasPremiumAccess: { [unowned self] in self.hasPremium },
                cloudProviders: { [unowned self] in self.cloudProviders },
                prewarm: {},
                openRecord: { _, _ in },
                openLanguageModelSettings: {},
                openPremium: {},
                isAllowedByPolicy: { [unowned self] in self.isAllowedByPolicy },
                accessChanges: accessChanges.eraseToAnyPublisher(),
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

    func testAProviderAddedWhileTheConsentShowsIsAskedForToo() throws {
        let model = try makeModel()
        model.send("Was habe ich heute diktiert?")
        cloudProviders.append((id: "other-llm", name: "Other LLM"))

        model.allowCloudProviders()
        XCTAssertEqual(model.consentProviders.map(\.name), ["Other LLM"])
        XCTAssertEqual(model.session.turns, [])
    }

    func testUnlockingPremiumUnlocksTheOpenPanel() async throws {
        let model = try makeModel(hasPremium: false)
        hasPremium = true
        accessChanges.send()
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.hasPremiumAccess, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.hasPremiumAccess)
    }

    func testTheOrganizationCanTurnAskHistoryOff() throws {
        isAllowedByPolicy = false
        let model = try makeModel()
        model.send("Was habe ich heute diktiert?")

        XCTAssertTrue(model.isTurnedOffByPolicy)
        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.session.turns, [])
    }

    func testTurningAskHistoryOffStopsTheRunningQuestion() throws {
        cloudProviders = []
        let model = try makeModel()
        model.send("Was habe ich heute diktiert?")
        XCTAssertTrue(model.session.isWorking)

        isAllowedByPolicy = false
        model.refreshAccess()
        XCTAssertFalse(model.session.isWorking)
        XCTAssertEqual(model.session.turns.map(\.stage), [.stopped])
    }

    func testAskingAboutRecordingsStartsANewConversationOnce() throws {
        cloudProviders = []
        let model = try makeModel()
        model.send("Was habe ich heute diktiert?")
        model.session.stop()
        let scope = AskHistoryConversationScope.records([UUID()], title: "Kick-off")

        model.ask(about: scope)
        XCTAssertEqual(model.session.scope, scope)
        XCTAssertEqual(model.session.turns, [])

        // The same recording again keeps the conversation about it.
        model.send("Was wurde beschlossen?")
        model.session.stop()
        model.ask(about: scope)
        XCTAssertEqual(model.session.turns.count, 1)
    }

    func testWithoutPremiumNothingIsAsked() throws {
        let model = try makeModel(hasPremium: false)
        model.send("Was habe ich heute diktiert?")

        XCTAssertFalse(model.hasPremiumAccess)
        XCTAssertFalse(model.needsConsent)
        XCTAssertEqual(model.session.turns, [])
    }
}
