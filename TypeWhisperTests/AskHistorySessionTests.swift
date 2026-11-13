import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

private func day(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

private func askRecord(_ id: UUID, title: String, text: String) -> HistorySearchRecord {
    HistorySearchRecord(
        id: id, recordedAt: day(10), source: RecordingSource.recorder.rawValue, originDeviceID: "device",
        language: "de", durationSeconds: 60, title: title, appName: nil, bundleID: nil, domain: nil, versionID: nil,
        fingerprint: HistorySearchFingerprint(version: "1", contentHash: "1"),
        passages: [HistoryPassage(kind: .transcript, text: text)]
    )
}

@MainActor
final class AskHistorySessionTests: XCTestCase {
    private let environment = AskHistoryTestEnvironment()
    private let posters = UUID()
    private let budget = UUID()

    override func tearDown() async throws {
        environment.cleanUp()
        try await super.tearDown()
    }

    private func makeSession(
        providers: [AnsweringProvider], prepareIndex: @escaping @MainActor () async -> Void = {}
    ) async throws -> AskHistorySession {
        let index = HistorySearchIndex(
            directory: try environment.makeDirectory().appendingPathComponent("index", isDirectory: true)
        )
        try await index.upsert([
            askRecord(posters, title: "Kick-off", text: "Anna: Ich bestelle 200 Plakate bei der Druckerei."),
            askRecord(budget, title: "Budget", text: "Ben: Das Budget für die Plakate steht bei 900 Euro."),
        ])
        return AskHistorySession(
            index: index,
            retriever: HistoryRetriever(index: index) { $0 },
            service: try environment.makeService(providers: providers),
            prepareIndex: prepareIndex,
            now: { day(12) }
        )
    }

    private func finish(_ session: AskHistorySession) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while session.isWorking {
            guard ContinuousClock.now < deadline else { return XCTFail("The question did not finish") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAFollowUpIsPlannedWithTheConversationAndKeepsWhatTheLastAnswerCited() async throws {
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let session = try await makeSession(providers: [provider])
        session.providerOverride = "cloud-llm"

        provider.enqueue(.text("Anna bestellt 200 Plakate [1]."))
        session.ask("  Wie viele Plakate bestellt Anna bei der Druckerei?  ")
        try await finish(session)

        let first = try XCTUnwrap(session.turns.first)
        XCTAssertEqual(first.question, "Wie viele Plakate bestellt Anna bei der Druckerei?")
        XCTAssertEqual(first.stage, .answered)
        XCTAssertEqual(first.answer?.text, "Anna bestellt 200 Plakate [1].")
        XCTAssertEqual(first.citedPassages.map(\.recordID), [posters])

        // "Und das Budget?" names one thing, so a model reads it with the conversation.
        provider.enqueue(.text(#"{"question": "Wie hoch ist das Budget für die Plakate?", "keywords": ["Budget"]}"#))
        provider.enqueue(.text("900 Euro [1]."))
        session.ask("Und das Budget?")
        try await finish(session)

        XCTAssertEqual(session.turns.map(\.stage), [.answered, .answered])
        XCTAssertTrue(provider.calls[1].systemPrompt.contains("JSON"), provider.calls[1].systemPrompt)
        let prompt = try XCTUnwrap(provider.calls.last?.userText)
        XCTAssertTrue(prompt.contains("900 Euro"), prompt)
        // The passage the first answer cited is still a source.
        XCTAssertTrue(prompt.contains("200 Plakate"), prompt)
        XCTAssertTrue(prompt.contains("Assistant: Anna bestellt 200 Plakate."), prompt)
    }

    func testWithoutALanguageModelTheTurnKeepsWhatTheSearchFound() async throws {
        let session = try await makeSession(providers: [])
        var prepared = false
        let preparing = try await makeSession(providers: []) { prepared = true }
        await preparing.prepare()
        XCTAssertTrue(prepared)

        session.ask("Wie viele Plakate bestellt Anna?")
        try await finish(session)

        XCTAssertEqual(session.turns.first?.stage, .needsLanguageModel)
        XCTAssertEqual(session.turns.first?.found.first?.recordID, posters)
        XCTAssertNil(session.turns.first?.answer)
    }

    func testAnOverviewOnALocalModelReportsItsProgress() async throws {
        let provider = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let session = try await makeSession(providers: [provider])
        session.providerOverride = "local-llm"
        provider.enqueue(.text("Budget von 900 Euro."))
        provider.enqueue(.text("200 Plakate bestellt."))

        session.ask("Fasse diese Woche zusammen")
        try await finish(session)

        let turn = try XCTUnwrap(session.turns.first)
        XCTAssertEqual(turn.stage, .answered)
        XCTAssertEqual(turn.answer?.sources.count, 2)
        XCTAssertEqual(turn.citedPassages, [])

        session.startNewConversation()
        XCTAssertEqual(session.turns, [])
    }
}
