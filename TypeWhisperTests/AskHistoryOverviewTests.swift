import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

private func day(_ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: 12))!
}

private func indexedRecord(
    _ id: UUID, on date: Date = day(10), title: String? = nil, hash: String = "1", passages: [HistoryPassage]
) -> HistorySearchRecord {
    HistorySearchRecord(
        id: id, recordedAt: date, source: RecordingSource.recorder.rawValue, originDeviceID: "device",
        language: "de", durationSeconds: 60, title: title, appName: nil, bundleID: nil, domain: nil, versionID: nil,
        fingerprint: HistorySearchFingerprint(version: hash, contentHash: hash), passages: passages
    )
}

private func spoken(_ text: String) -> HistoryPassage {
    HistoryPassage(kind: .transcript, text: text)
}

final class AskHistoryFollowUpPlanTests: XCTestCase {
    func testAPlanIsReadFromAReplyThatWrapsItsJSON() {
        let reply = """
            Here is the plan:
            ```json
            {"question": "Was hat Ben zu den Plakaten gesagt?", "keywords": ["Plakate", "Druckerei", "plakate", " "]}
            ```
            """
        XCTAssertEqual(
            AskHistoryFollowUpPlan(reply: reply),
            AskHistoryFollowUpPlan(question: "Was hat Ben zu den Plakaten gesagt?", keywords: ["Plakate", "Druckerei"])
        )
        // Small models return the list as one string.
        XCTAssertEqual(
            AskHistoryFollowUpPlan(reply: #"{"keywords": "Plakate, Druckerei"}"#)?.keywords, ["Plakate", "Druckerei"]
        )
        XCTAssertNil(AskHistoryFollowUpPlan(reply: "I cannot help with that."))
        XCTAssertNil(AskHistoryFollowUpPlan(reply: #"{"question": "", "keywords": []}"#))
    }

    func testAFollowUpThatNamesLittleIsReadWithTheConversation() {
        let planner = AskHistoryPlanner(
            vocabulary: HistorySearchVocabulary(speakers: ["Ben"]), now: day(12), calendar: Calendar(identifier: .gregorian)
        )
        let history = [
            AskHistoryTurn(role: .user, text: "Was wurde zu den Plakaten beschlossen?"),
            AskHistoryTurn(role: .assistant, text: "Anna bestellt 200 Plakate [1]."),
        ]
        let question = "Und was hat Ben gestern dazu gesagt?"
        let own = planner.plan(for: question)

        XCTAssertTrue(AskHistoryPlanner.needsFollowUpPlan(own, history: history))
        XCTAssertFalse(AskHistoryPlanner.needsFollowUpPlan(own, history: []))
        XCTAssertFalse(AskHistoryPlanner.needsFollowUpPlan(planner.plan(for: "Was kostet die Druckerei für die Plakate?"), history: history))

        // The model invents a period; only the question's own counts.
        let followUp = AskHistoryFollowUpPlan(
            question: "Was hat Ben letztes Jahr zu den Plakaten gesagt?", keywords: ["Plakate", "Druckerei", "Ben", "gesagt"]
        )
        let plan = planner.plan(for: question, followUp: followUp)
        XCTAssertEqual(plan.names, ["Ben"])
        XCTAssertTrue(plan.keywords.contains("Druckerei"), "\(plan.keywords)")
        XCTAssertTrue(plan.keywords.contains { $0.lowercased().hasPrefix("plakat") }, "\(plan.keywords)")
        XCTAssertEqual(plan.keywords.filter { ["Ben", "gesagt"].contains($0) }, [])
        XCTAssertEqual(plan.scope.period, own.scope.period)
        XCTAssertEqual(plan.question, question)
    }
}

@MainActor
final class AskHistoryOverviewTests: XCTestCase {
    private let environment = AskHistoryTestEnvironment()

    override func tearDown() async throws {
        environment.cleanUp()
        try await super.tearDown()
    }

    private func makeIndex() throws -> HistorySearchIndex {
        HistorySearchIndex(directory: try environment.makeDirectory().appendingPathComponent("index", isDirectory: true))
    }

    func testASummaryIsKeptUntilItsRecordChangesOrIsRemoved() async throws {
        let index = try makeIndex()
        let meeting = UUID(), note = UUID()
        try await index.upsert([
            indexedRecord(meeting, passages: [
                spoken("Anna: Erster Teil."), spoken("Ben: Zweiter Teil."),
                HistoryPassage(kind: .result, text: "Notizen zum Meeting"),
            ]),
            indexedRecord(note, passages: [spoken("Eine Notiz.")]),
        ])

        // Only what was said, in order.
        let transcript = try await index.transcript(ofRecord: meeting)
        XCTAssertEqual(transcript?.passages.map(\.text), ["Anna: Erster Teil.", "Ben: Zweiter Teil."])
        XCTAssertEqual(transcript?.contentHash, "1")
        var summary = try await index.summary(ofRecord: meeting)?.text
        XCTAssertNil(summary)

        try await index.setSummary("Zwei Teile.", providerId: "local-llm", ofRecord: meeting, contentHash: "1")
        try await index.setSummary("Notiz.", providerId: "local-llm", ofRecord: note, contentHash: "1")
        try await index.setSummary("Unbekannt.", providerId: "local-llm", ofRecord: UUID(), contentHash: "1")
        let kept = try await index.summary(ofRecord: meeting)
        XCTAssertEqual(kept?.text, "Zwei Teile.")
        XCTAssertEqual(kept?.providerId, "local-llm")

        // A changed record loses its summary, a removed one too.
        try await index.upsert([indexedRecord(meeting, hash: "2", passages: [spoken("Anna: Neuer Text.")])])
        summary = try await index.summary(ofRecord: meeting)?.text
        XCTAssertNil(summary)
        // A summary of the text before the change, finished after it, is not kept.
        try await index.setSummary("Zwei Teile.", providerId: "local-llm", ofRecord: meeting, contentHash: "1")
        summary = try await index.summary(ofRecord: meeting)?.text
        XCTAssertNil(summary)
        try await index.remove([note])
        try await index.upsert([indexedRecord(note, passages: [spoken("Eine Notiz.")])])
        summary = try await index.summary(ofRecord: note)?.text
        XCTAssertNil(summary)
    }

    func testALongRecordingIsSummarizedInPartsAndAShortOneInOneRequest() async throws {
        let provider = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let service = try environment.makeService(providers: [provider])

        provider.enqueue(.text(" Anna bestellt Plakate. "))
        let short = try await service.summarizeHistoryRecording(
            passages: ["Anna: Ich bestelle 200 Plakate.", "Ben: Gut."], title: "Kick-off", providerOverride: "local-llm"
        )
        XCTAssertEqual(short.text, "Anna bestellt Plakate.")
        XCTAssertEqual(short.providerId, "local-llm")
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertTrue(provider.calls[0].systemPrompt.hasPrefix("You summarize one recording of the user"))
        XCTAssertEqual(provider.calls[0].userText, """
            RECORDING
            Title: Kick-off
            Anna: Ich bestelle 200 Plakate.
            Ben: Gut.
            END_RECORDING
            """)

        // A local model takes 12,000 characters at a time: three parts and one request for the whole.
        let passages = (1...3).map { "Teil \($0): " + String(repeating: "Wort ", count: 1_700) }
        for reply in ["Erstens.", "Zweitens.", "Drittens.", "Alles zusammen."] {
            provider.enqueue(.text(reply))
        }
        let long = try await service.summarizeHistoryRecording(passages: passages, title: nil, providerOverride: "local-llm")
        XCTAssertEqual(long.text, "Alles zusammen.")
        XCTAssertEqual(provider.calls.count, 5)
        XCTAssertTrue(provider.calls[2].userText.hasPrefix("RECORDING\nPart 2 of 3\nTeil 2: "))
        XCTAssertEqual(provider.calls[4].userText, "PARTS\n1. Erstens.\n2. Zweitens.\n3. Drittens.\nEND_PARTS")

        // Text that exceeds the context in tokens is summarized again in smaller parts.
        for reply in ["This model's maximum context length is 8192 tokens.", "A.", "B.", "A und B."] {
            provider.enqueue(reply.hasPrefix("This") ? .failure(reply) : .text(reply))
        }
        let dense = try await service.summarizeHistoryRecording(
            passages: [String(repeating: "字", count: 5_000), String(repeating: "词", count: 5_000)],
            title: nil, providerOverride: "local-llm"
        )
        XCTAssertEqual(dense.text, "A und B.")
        XCTAssertEqual(provider.calls.count, 9)

        // Summaries too long to combine at once are combined in steps.
        let longSummary = String(repeating: "Satz. ", count: 1_200)
        for reply in [longSummary, longSummary, longSummary, "Erste zwei.", "Alle drei."] {
            provider.enqueue(.text(reply))
        }
        let stepwise = try await service.summarizeHistoryRecording(passages: passages, title: nil, providerOverride: "local-llm")
        XCTAssertEqual(stepwise.text, "Alle drei.")
        XCTAssertEqual(provider.calls.count, 14)
        XCTAssertTrue(provider.calls[13].userText.hasPrefix("PARTS\n1. Erste zwei.\n2. Satz."))
    }

    func testAModelReadsAFollowUpAndAFailureLeavesTheQuestionAsItIs() async throws {
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let service = try environment.makeService(providers: [provider])
        let history = [
            AskHistoryTurn(role: .user, text: "Was wurde zu den Plakaten beschlossen?"),
            AskHistoryTurn(role: .assistant, text: "Anna bestellt 200 Plakate [1]."),
        ]

        provider.enqueue(.text(#"{"question": "Was hat Ben zu den Plakaten gesagt?", "keywords": ["Plakate"]}"#))
        var plan = await service.planHistoryFollowUp(question: "Und Ben?", history: history, providerOverride: "cloud-llm")
        XCTAssertEqual(plan, AskHistoryFollowUpPlan(question: "Was hat Ben zu den Plakaten gesagt?", keywords: ["Plakate"]))
        XCTAssertEqual(provider.calls.last?.userText, """
            CONVERSATION
            User: Was wurde zu den Plakaten beschlossen?

            Assistant: Anna bestellt 200 Plakate [1].
            END_CONVERSATION

            QUESTION
            Und Ben?
            END_QUESTION
            """)

        provider.enqueue(.failure("The provider failed."))
        plan = await service.planHistoryFollowUp(question: "Und Ben?", history: history, providerOverride: "cloud-llm")
        XCTAssertNil(plan)
    }

    func testAnOverviewOnALocalModelIsTheListOfASummaryOfEachRecording() async throws {
        let index = try makeIndex()
        let ids = [UUID(), UUID(), UUID()]
        try await index.upsert(ids.enumerated().map { offset, id in
            indexedRecord(id, on: day(9 + offset), title: "Aufnahme \(offset + 1)", passages: [
                spoken("Anfang von Aufnahme \(offset + 1)."), spoken("Ende von Aufnahme \(offset + 1)."),
            ])
        })
        let provider = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let service = try environment.makeService(providers: [provider])
        XCTAssertEqual(service.historyOverviewProvider(providerOverride: "local-llm")?.usesSummaries, true)
        let overview = AskHistoryOverview(index: index, service: service)
        let plan = HistorySearchPlan(question: "Fasse die Woche zusammen")
        let retrieval = try await HistoryRetriever(index: index) { $0 }.retrieve(plan, limit: 20)
        XCTAssertEqual(retrieval.hits.map(\.recordID), ids.reversed())

        for reply in ["Summe 3.", "Summe 2.\nMit Zusatz.", "Summe 1."] {
            provider.enqueue(.text(reply))
        }
        var progress: [String] = []
        var answer = try await overview.answer(plan: plan, retrieval: retrieval, providerOverride: "local-llm") {
            progress.append("\($0) of \($1)")
        }

        // The overview is the list of the summaries; no request writes it.
        XCTAssertEqual(answer.text, """
            - Aufnahme 3: Summe 3. [1]
            - Aufnahme 2: Summe 2. Mit Zusatz. [2]
            - Aufnahme 1: Summe 1. [3]
            """)
        XCTAssertEqual(answer.sources.map(\.text), ["Summe 3.", "Summe 2.\nMit Zusatz.", "Summe 1."])
        XCTAssertEqual(answer.sources.map(\.recordID), ids.reversed())
        XCTAssertEqual(answer.citedSources, [1, 2, 3])
        XCTAssertEqual(answer.providerName, "Local LLM")
        XCTAssertEqual(progress, ["1 of 3", "2 of 3", "3 of 3"])
        XCTAssertEqual(provider.calls.count, 3)
        // The whole recording is summarized, not only its beginning.
        XCTAssertTrue(provider.calls[0].userText.contains("Anfang von Aufnahme 3.\nEnde von Aufnahme 3."))

        // A second overview only summarizes the recording that changed since.
        try await index.upsert([indexedRecord(ids[0], on: day(9), title: "Aufnahme 1", hash: "2", passages: [spoken("Neuer Text.")])])
        provider.enqueue(.text("Neue Summe 1."))
        progress = []
        let partial = HistoryRetrieval(hits: retrieval.hits, recordCount: 5)
        answer = try await overview.answer(plan: plan, retrieval: partial, providerOverride: "local-llm") {
            progress.append("\($0) of \($1)")
        }
        XCTAssertEqual(answer.sources.map(\.text), ["Summe 3.", "Summe 2.\nMit Zusatz.", "Neue Summe 1."])
        XCTAssertEqual(answer.omittedRecordCount, 2)
        XCTAssertEqual(progress, ["1 of 1"])
        XCTAssertEqual(provider.calls.count, 4)
    }

    func testAnOverviewIsWrittenInTheQuestionsLanguageAndSaysWhenItHasNoRecordings() async throws {
        let index = try makeIndex()
        let id = UUID()
        try await index.upsert([indexedRecord(id, title: "Aufnahme", passages: [spoken("Anna bestellt Plakate.")])])
        try await index.setSummary("Anna bestellt Plakate.", providerId: "local-llm", ofRecord: id, contentHash: "1")
        let provider = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let service = try environment.makeService(providers: [provider])
        let overview = AskHistoryOverview(index: index, service: service)
        var plan = HistorySearchPlan(question: "Summarize this week")
        plan.language = "en"
        let retrieval = try await HistoryRetriever(index: index) { $0 }.retrieve(plan, limit: 20)

        // A summary in the recording's language is not reused for an English question.
        provider.enqueue(.text("Anna orders posters."))
        var answer = try await overview.answer(plan: plan, retrieval: retrieval, providerOverride: "local-llm")
        XCTAssertEqual(answer.text, "- Aufnahme: Anna orders posters. [1]")
        XCTAssertTrue(provider.calls[0].systemPrompt.contains("Write one to three sentences in English:"))

        // Without recordings the model answers that there are none.
        provider.enqueue(.text("There are no recordings this week."))
        answer = try await overview.answer(plan: plan, retrieval: HistoryRetrieval(hits: [], recordCount: 0), providerOverride: "local-llm")
        XCTAssertEqual(answer.text, "There are no recordings this week.")
        XCTAssertEqual(answer.sources, [])
    }

    func testAnOverviewNamesTheProviderThatWroteItsSummaries() async throws {
        let index = try makeIndex()
        let id = UUID()
        try await index.upsert([indexedRecord(id, title: "Aufnahme", passages: [spoken("Text.")])])
        let local = AnsweringProvider(id: "local-llm", name: "Local LLM", isLocal: true)
        let cloud = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let service = try environment.makeService(providers: [local, cloud], fallbacks: ["local-llm", "cloud-llm"])
        local.enqueue(.failure("The provider failed."))
        cloud.enqueue(.text("Summe."))
        let plan = HistorySearchPlan(question: "Fasse die Woche zusammen")
        let retrieval = try await HistoryRetriever(index: index) { $0 }.retrieve(plan, limit: 20)

        let answer = try await AskHistoryOverview(index: index, service: service).answer(plan: plan, retrieval: retrieval)

        XCTAssertEqual(answer.text, "- Aufnahme: Summe. [1]")
        XCTAssertEqual(answer.providerId, "cloud-llm")
        XCTAssertEqual(answer.providerName, "Cloud LLM")
    }

    func testAnOverviewOnACloudModelGetsTheBeginningOfEveryRecordingInOnePrompt() async throws {
        let index = try makeIndex()
        try await index.upsert((1...3).map { number in
            indexedRecord(UUID(), on: day(8 + number), passages: [spoken("Anfang \(number)."), spoken("Ende \(number).")])
        })
        let provider = AnsweringProvider(id: "cloud-llm", name: "Cloud LLM")
        let service = try environment.makeService(providers: [provider])
        XCTAssertEqual(service.historyOverviewProvider(providerOverride: "cloud-llm")?.usesSummaries, false)
        let plan = HistorySearchPlan(question: "Fasse die Woche zusammen")
        let retrieval = try await HistoryRetriever(index: index) { $0 }.retrieve(plan, limit: 20)

        provider.enqueue(.text("Überblick [1]."))
        let answer = try await AskHistoryOverview(index: index, service: service)
            .answer(plan: plan, retrieval: retrieval, providerOverride: "cloud-llm")

        XCTAssertEqual(answer.sources.map(\.text), ["Anfang 3.", "Anfang 2.", "Anfang 1."])
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertTrue(provider.calls[0].systemPrompt.contains("SOURCES hold the beginning of every recording"))
    }
}
