import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

private func day(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

private func askRecord(_ id: UUID, title: String, text: String, more: [String] = []) -> HistorySearchRecord {
    HistorySearchRecord(
        id: id, recordedAt: day(10), source: RecordingSource.recorder.rawValue, originDeviceID: "device",
        language: "de", durationSeconds: 60, title: title, appName: nil, bundleID: nil, domain: nil, versionID: nil,
        fingerprint: HistorySearchFingerprint(version: "1", contentHash: "1"),
        passages: ([text] + more).map { HistoryPassage(kind: .transcript, text: $0) }
    )
}

@MainActor
final class AskHistorySessionTests: XCTestCase {
    private let environment = AskHistoryTestEnvironment()
    private let posters = UUID()
    private let budget = UUID()
    private let meeting = UUID()

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
            askRecord(meeting, title: "Planung", text: "Carla: Der Start ist am Montag.", more: [
                "Dan: Die Pressemitteilung schreibe ich.", "Carla: Entschieden: Wir verschieben die Messe.",
            ]),
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

        // A follow-up about another day keeps no earlier passage from outside it.
        provider.enqueue(.text(#"{"question": "Was wurde gestern zum Budget gesagt?", "keywords": ["Budget"]}"#))
        provider.enqueue(.text("Dazu gibt es nichts."))
        session.ask("Und gestern?")
        try await finish(session)
        XCTAssertTrue(provider.calls.last?.userText.hasPrefix("SOURCES\nEND_SOURCES") == true, provider.calls.last?.userText ?? "")
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

    func testAQuestionWaitsForTheIndexAndANewConversationReleasesIt() async throws {
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let session = try await makeSession(providers: [provider]) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        session.providerOverride = "cloud-llm"
        let preparing = Task { await session.prepare() }
        try await Task.sleep(for: .milliseconds(50))
        // A caller that gives up stops waiting at once.
        let started = ContinuousClock.now
        let waiting = Task { await session.prepare() }
        waiting.cancel()
        await waiting.value
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(300))

        session.ask("Wie viele Plakate bestellt Anna?")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.turns.first?.stage, .preparingIndex)

        // Stopping and starting over free the session at once for the next question.
        session.stop()
        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(session.turns.first?.stage, .stopped)
        session.startNewConversation()
        XCTAssertFalse(session.isWorking)
        provider.enqueue(.text("200 Plakate [1]."))
        session.ask("Wie viele Plakate bestellt Anna?")
        XCTAssertEqual(session.turns.count, 1)
        await preparing.value
        try await finish(session)
        XCTAssertEqual(session.turns.map(\.stage), [.answered])
        XCTAssertEqual(provider.calls.count, 1)
    }

    func testAScopeIncludesAPassageFromItsStartToBeforeItsEnd() {
        let hit = HistorySearchHit(
            recordID: UUID(), recordedAt: day(11), source: RecordingSource.mac.rawValue, ordinals: 0...0,
            passage: HistoryPassage(kind: .transcript, text: "Text")
        )
        XCTAssertTrue(HistorySearchScope(period: DateInterval(start: day(11), end: day(12))).includes(hit))
        XCTAssertFalse(HistorySearchScope(period: DateInterval(start: day(10), end: day(11))).includes(hit))
        XCTAssertFalse(HistorySearchScope(sources: [RecordingSource.iPhone.rawValue]).includes(hit))
        XCTAssertFalse(HistorySearchScope(bundleIDs: ["com.tinyspeck.slackmacgap"]).includes(hit))
    }

    func testAQuestionAboutOneRecordingSearchesOnlyItAndReadsItWhenNoWordMatches() async throws {
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let session = try await makeSession(providers: [provider])
        session.providerOverride = "cloud-llm"
        session.scope = .records([budget], title: "Budget")

        // "Plakate" is in both recordings; only the scoped one is a source.
        provider.enqueue(.text("900 Euro [1]."))
        session.ask("Was kosten die Plakate?")
        try await finish(session)
        var prompt = try XCTUnwrap(provider.calls.last?.userText)
        XCTAssertTrue(prompt.contains("900 Euro"), prompt)
        XCTAssertFalse(prompt.contains("200 Plakate"), prompt)

        // No word of the question is in it: the model reads the recording itself.
        session.startNewConversation()
        session.scope = .records([posters], title: "Kick-off")
        provider.enqueue(.text("Anna bestellt Plakate [1]."))
        session.ask("Was wurde vereinbart?")
        try await finish(session)
        prompt = try XCTUnwrap(provider.calls.last?.userText)
        XCTAssertTrue(prompt.contains("200 Plakate"), prompt)
        XCTAssertFalse(prompt.contains("900 Euro"), prompt)
    }

    func testAnOverviewOfOneRecordingReadsAllOfIt() async throws {
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let session = try await makeSession(providers: [provider])
        session.providerOverride = "cloud-llm"
        session.scope = .records([meeting], title: "Planung")

        provider.enqueue(.text("Start am Montag [1], die Messe wird verschoben [3]."))
        session.ask("Fasse diese Aufnahme zusammen")
        try await finish(session)

        let call = try XCTUnwrap(provider.calls.last)
        XCTAssertTrue(call.userText.contains("Wir verschieben die Messe"), call.userText)
        XCTAssertFalse(call.userText.contains("900 Euro"), call.userText)
        // Still an overview, with its budget, but of whole recordings.
        XCTAssertFalse(call.systemPrompt.contains("beginning"), call.systemPrompt)
        XCTAssertTrue(call.systemPrompt.contains("SOURCES hold every recording the question is about, each from its start"), call.systemPrompt)
    }

    func testAnOverviewOnALocalModelReportsItsProgress() async throws {
        let provider = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let session = try await makeSession(providers: [provider])
        session.providerOverride = "local-llm"
        provider.enqueue(.text("Budget von 900 Euro."))
        provider.enqueue(.text("200 Plakate bestellt."))
        provider.enqueue(.text("Messe verschoben."))

        session.ask("Fasse diese Woche zusammen")
        try await finish(session)

        let turn = try XCTUnwrap(session.turns.first)
        XCTAssertEqual(turn.stage, .answered)
        XCTAssertEqual(turn.answer?.sources.count, 3)
        XCTAssertEqual(turn.citedPassages, [])

        session.startNewConversation()
        XCTAssertEqual(session.turns, [])
    }
}
