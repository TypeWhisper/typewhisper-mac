import XCTest
@testable import TypeWhisper

/// Thursday, November 12, 2026, 10:00 in Berlin, with weeks that start on Monday.
private enum TestClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10))!

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

final class HistoryPeriodResolverTests: XCTestCase {
    /// The period's first day and the day after its last one.
    private func period(_ question: String, _ language: String? = nil) -> String? {
        let resolver = HistoryPeriodResolver(now: TestClock.now, calendar: TestClock.calendar)
        guard let period = resolver.period(in: question, language: language) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = TestClock.calendar
        formatter.timeZone = TestClock.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: period.interval.start) + "/" + formatter.string(from: period.interval.end)
    }

    func testPeriodsOfThePastAreFoundInFiveLanguages() {
        let today = "2026-11-12/2026-11-13"
        let yesterday = "2026-11-11/2026-11-12"
        let lastWeek = "2026-11-02/2026-11-09"
        let october = "2026-10-01/2026-11-01"
        let lastYear = "2025-01-01/2026-01-01"
        let twoWeeksAgo = "2026-10-26/2026-11-02"
        let thirdOfNovember = "2026-11-03/2026-11-04"
        let cases: [(question: String, language: String, period: String)] = [
            ("Was habe ich heute diktiert?", "de", today),
            ("Was wurde gestern besprochen?", "de", yesterday),
            ("Fasse meine Meetings von letzter Woche zusammen", "de", lastWeek),
            ("Was war im Oktober?", "de", october),
            ("Was war letzten Monat?", "de", october),
            ("Was war im letzten Jahr?", "de", lastYear),
            ("Was war vor zwei Wochen?", "de", twoWeeksAgo),
            ("Was war in den letzten zwei Wochen?", "de", "2026-10-29/2026-11-13"),
            ("Was war am Montag?", "de", "2026-11-09/2026-11-10"),
            ("Was war am Donnerstag?", "de", today),
            ("Was war letzten Donnerstag?", "de", "2026-11-05/2026-11-06"),
            ("Was war seit Montag?", "de", "2026-11-09/2026-11-13"),
            ("Was war am 3. November?", "de", thirdOfNovember),
            ("Was war am 3.11.?", "de", thirdOfNovember),
            ("Was war am 24. Dezember?", "de", "2025-12-24/2025-12-25"),
            ("Was war im Dezember?", "de", "2025-12-01/2026-01-01"),
            ("Was war Anfang März 2025?", "de", "2025-03-01/2025-04-01"),
            ("What did I say today?", "en", today),
            ("What did I say last week?", "en", lastWeek),
            ("What did I say two weeks ago?", "en", twoWeeksAgo),
            ("What did I say the day before yesterday?", "en", "2026-11-10/2026-11-11"),
            ("What did I say on November 3rd?", "en", thirdOfNovember),
            ("What did I say on 2026-11-03?", "en", thirdOfNovember),
            ("What did I say since 2026-11-03?", "en", "2026-11-03/2026-11-13"),
            ("What did I say since November 3, 2025?", "en", "2025-11-03/2026-11-13"),
            ("Summarize my recordings for last week", "en", lastWeek),
            ("What may I have said in March 2026?", "en", "2026-03-01/2026-04-01"),
            ("What did I say in 2025?", "en", lastYear),
            ("Qu'est-ce que j'ai dit hier ?", "fr", yesterday),
            ("Qu'est-ce que j'ai dit la semaine dernière ?", "fr", lastWeek),
            ("Qu'est-ce que j'ai dit il y a deux semaines ?", "fr", twoWeeksAgo),
            ("Qu'est-ce que j'ai dit le 3 novembre ?", "fr", thirdOfNovember),
            ("¿Qué dije ayer?", "es", yesterday),
            ("¿Qué dije la semana pasada?", "es", lastWeek),
            ("¿Qué dije el 3 de noviembre de 2026?", "es", thirdOfNovember),
            ("¿Qué dije hace dos semanas?", "es", twoWeeksAgo),
            ("Cosa ho detto ieri?", "it", yesterday),
            ("Cosa ho detto la settimana scorsa?", "it", lastWeek),
            ("Cosa ho detto due settimane fa?", "it", twoWeeksAgo),
            ("Cosa ho detto a ottobre?", "it", october),
        ]
        for (question, language, expected) in cases {
            XCTAssertEqual(period(question, language), expected, question)
        }
    }

    func testWordsThatOnlyLookLikeAPeriodAreLeftAlone() {
        let cases: [(question: String, language: String)] = [
            // German "hier" is "here", French "hier" is yesterday.
            ("Was wurde hier besprochen?", "de"),
            ("What may I have said about the march?", "en"),
            ("Non ho mai detto questo", "it"),
            ("Version 1.8.3 ist raus", "de"),
            ("What costs 2000 dollars?", "en"),
            // Dates in what was said, not when it was said.
            ("What did Elena promise for Wednesday?", "en"),
            ("Was muss bis Donnerstag fertig sein?", "de"),
            ("Qu'est-ce qui est prévu lundi prochain ?", "fr"),
            ("Was ist am 24.12.2026 geplant?", "de"),
            ("What did Elena promise for 2026-11-04?", "en"),
            ("What did Elena promise to deliver by last Friday?", "en"),
        ]
        for (question, language) in cases {
            XCTAssertNil(period(question, language), question)
        }
    }

    func testAPeriodNamesItsWordsSoTheyAreNotSearchedFor() throws {
        let question = "Was hat Anna letzte Woche am Montag gesagt?"
        let resolver = HistoryPeriodResolver(now: TestClock.now, calendar: TestClock.calendar)
        let period = try XCTUnwrap(resolver.period(in: question, language: "de"))

        XCTAssertEqual(
            period.utf16Ranges.map { (question as NSString).substring(with: NSRange($0)) },
            ["letzte Woche", "Montag"]
        )
        // The first period counts.
        XCTAssertEqual(period.interval.start, TestClock.date(2026, 11, 2, hour: 0))
    }
}

final class HistoryFullTextQueryTests: XCTestCase {
    func testOnlyQuotedWordsOfAQuestionReachTheQuery() {
        XCTAssertEqual(
            HistoryFullTextQuery.expression(words: ["Druckerei", "x\" OR NEAR(a b) -c*", "ab"], names: ["Anna Lang"]),
            #""druckerei"* OR "x" OR "or" OR "near"* OR "a" OR "b" OR "c" OR "ab" OR "anna lang""#
        )
        XCTAssertNil(HistoryFullTextQuery.expression(words: ["\"*-", ""], names: [" "]))
    }

    func testGermanWordsAreSearchedInBothSpellings() {
        XCTAssertEqual(HistoryFullTextQuery.expression(words: ["Müller"]), #""müller"* OR "mueller"*"#)
        XCTAssertEqual(HistoryFullTextQuery.expression(words: ["Strasse"]), #""strasse"* OR "straße"*"#)
        XCTAssertEqual(HistoryFullTextQuery.expression(words: [], names: ["Jörg Weiß"]), #""jörg weiß" OR "joerg weiss""#)
    }
}

final class AskHistoryPlannerTests: XCTestCase {
    private let slack = HistorySearchVocabulary.App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")

    private func plan(_ question: String, _ vocabulary: HistorySearchVocabulary = HistorySearchVocabulary()) -> HistorySearchPlan {
        AskHistoryPlanner(vocabulary: vocabulary, now: TestClock.now, calendar: TestClock.calendar).plan(for: question)
    }

    func testAQuestionBecomesKeywordsNamesAndAPeriod() {
        let vocabulary = HistorySearchVocabulary(speakers: ["Anna Lang", "Speaker 2"])
        let plan = plan("Was hat Anna letzte Woche zur Druckerei gesagt?", vocabulary)

        XCTAssertEqual(plan.names, ["Anna"])
        XCTAssertTrue(plan.keywords.contains("Druckerei"), "\(plan.keywords)")
        // Not the period, the name or the words that only frame the question.
        let framing = plan.keywords.filter { ["letzte", "Woche", "Anna", "gesagt", "hat"].contains($0) }
        XCTAssertEqual(framing, [])
        XCTAssertEqual(plan.scope.period?.start, TestClock.date(2026, 11, 2, hour: 0))
        XCTAssertEqual(plan.intent, .lookup)

        // A speaker nobody named is no name to ask about.
        XCTAssertEqual(self.plan("What did the speaker say about the budget?", vocabulary).names, [])
    }

    func testAQuestionWithoutATopicReadsItsPartOfHistory() {
        let plan = plan("Fasse meine Meetings von letzter Woche zusammen")

        XCTAssertEqual(plan.keywords, [])
        XCTAssertEqual(plan.intent, .overview)
        XCTAssertNotNil(plan.scope.period)
    }

    func testAppsDomainsAndDevicesLimitTheSearchWhereTheQuestionPlacesItThere() {
        let vocabulary = HistorySearchVocabulary(apps: [slack], domains: ["github.com", "gist.github.com"])

        let inSlack = plan("Was habe ich gestern in Slack geschrieben?", vocabulary)
        XCTAssertEqual(inSlack.scope.bundleIDs, [slack.bundleID])
        XCTAssertEqual(inSlack.keywords, [])

        // About the app, not written in it.
        let aboutSlack = plan("Was hat Ben über Slack gesagt?", vocabulary)
        XCTAssertEqual(aboutSlack.scope.bundleIDs, [])
        XCTAssertTrue(aboutSlack.keywords.contains("Slack"), "\(aboutSlack.keywords)")

        let onGitHub = plan("Was habe ich auf github.com zum Pull Request geschrieben?", vocabulary)
        XCTAssertEqual(onGitHub.scope.domains, ["github.com"])
        XCTAssertFalse(onGitHub.keywords.contains { $0.lowercased().contains("github") }, "\(onGitHub.keywords)")
        XCTAssertEqual(plan("Was stand auf gist.github.com?", vocabulary).scope.domains, ["gist.github.com"])
        // Next to an app, a host without "on" is what was written about.
        let aboutGitHub = plan("What did I write in Slack about github.com?", vocabulary)
        XCTAssertEqual(aboutGitHub.scope.domains, [])
        XCTAssertTrue(aboutGitHub.keywords.contains("github.com"), "\(aboutGitHub.keywords)")
        // A weekday inside a host names no day.
        let onMonday = plan("What did I write on monday.com about monday.com?", HistorySearchVocabulary(domains: ["monday.com"]))
        XCTAssertEqual(onMonday.scope.domains, ["monday.com"])
        XCTAssertNil(onMonday.scope.period)

        let onPhone = plan("What did I dictate on my iPhone about the passport?", vocabulary)
        XCTAssertEqual(onPhone.scope.sources, [RecordingSource.iPhone.rawValue, RecordingSource.keyboard.rawValue])
        XCTAssertTrue(onPhone.keywords.contains("passport"), "\(onPhone.keywords)")
    }

    func testAQuestionAboutTheLastTimePrefersNewRecords() {
        XCTAssertTrue(plan("Wann habe ich zuletzt über die Heizung gesprochen?").prefersNewest)
        XCTAssertTrue(plan("When did we last time talk about the heating?").prefersNewest)
        XCTAssertFalse(plan("Was wurde zur Heizung gesagt?").prefersNewest)
    }
}

final class HistoryRetrievalTests: XCTestCase {
    private func record(
        _ id: UUID = UUID(),
        at date: Date = TestClock.date(2026, 11, 10),
        source: RecordingSource = .mac,
        title: String? = nil,
        app: HistorySearchVocabulary.App? = nil,
        domain: String? = nil,
        passages: [HistoryPassage]
    ) -> HistorySearchRecord {
        HistorySearchRecord(
            id: id, recordedAt: date, source: source.rawValue, originDeviceID: "device", language: "de",
            durationSeconds: 5, title: title, appName: app?.name, bundleID: app?.bundleID, domain: domain,
            versionID: nil, fingerprint: HistorySearchFingerprint(version: "1", contentHash: "1"), passages: passages
        )
    }

    private func passage(_ text: String, speakers: [String] = []) -> HistoryPassage {
        HistoryPassage(kind: .transcript, text: text, speakers: speakers)
    }

    private func makeIndex() throws -> (index: HistorySearchIndex, directory: URL) {
        let directory = try TestSupport.makeTemporaryDirectory()
        return (HistorySearchIndex(directory: directory.appendingPathComponent("index", isDirectory: true)), directory)
    }

    func testSearchFindsWordStartsOtherSpellingsSpeakersAndPartsOfLongerWords() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let dentist = UUID(), invoice = UUID(), posters = UUID()
        try await index.upsert([
            record(dentist, passages: [passage("Termin beim Kinderzahnarzt für Emil")]),
            record(invoice, passages: [passage("Die Rechnung ging an Herrn Müller")]),
            record(posters, passages: [passage("Die Plakate sind bestellt", speakers: ["Anna"])]),
        ])

        func found(_ words: [String], names: [String] = []) async throws -> [UUID] {
            try await index.search(words: words, names: names).map(\.recordID)
        }
        let byWordStart = try await found(["Plakat"])
        XCTAssertEqual(byWordStart, [posters])
        let byOtherSpelling = try await found(["Mueller"])
        XCTAssertEqual(byOtherSpelling, [invoice])
        let bySpeaker = try await found([], names: ["Anna"])
        XCTAssertEqual(bySpeaker, [posters])
        let byPartOfAWord = try await found(["Zahnarzt"])
        XCTAssertEqual(byPartOfAWord, [dentist])
        let byOperators = try await found(["\" OR NEAR(", "-"])
        XCTAssertEqual(byOperators, [])
    }

    func testSearchKeepsToThePeriodAppDomainAndDeviceOfItsScope() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let slack = HistorySearchVocabulary.App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let old = UUID(), inSlack = UUID(), onGitHub = UUID(), onPhone = UUID()
        try await index.upsert([
            record(old, at: TestClock.date(2026, 10, 1), passages: [passage("Budget im Oktober")]),
            record(inSlack, app: slack, passages: [passage("Budget in Slack")]),
            record(onGitHub, domain: "github.com", passages: [passage("Budget im Browser")]),
            record(onPhone, source: .iPhone, passages: [passage("Budget unterwegs")]),
        ])

        func found(_ scope: HistorySearchScope) async throws -> Set<UUID> {
            Set(try await index.search(words: ["Budget"], in: scope).map(\.recordID))
        }
        let everywhere = try await found(HistorySearchScope())
        XCTAssertEqual(everywhere, [old, inSlack, onGitHub, onPhone])
        let october = DateInterval(start: TestClock.date(2026, 10, 1, hour: 0), end: TestClock.date(2026, 11, 1, hour: 0))
        let inOctober = try await found(HistorySearchScope(period: october))
        XCTAssertEqual(inOctober, [old])
        let inApp = try await found(HistorySearchScope(bundleIDs: [slack.bundleID]))
        XCTAssertEqual(inApp, [inSlack])
        let onDomain = try await found(HistorySearchScope(domains: ["github.com"]))
        XCTAssertEqual(onDomain, [onGitHub])
        let onDevice = try await found(HistorySearchScope(sources: [RecordingSource.iPhone.rawValue]))
        XCTAssertEqual(onDevice, [onPhone])

        // An overview reads the same scope, newest first.
        let overview = try await index.newestRecords(in: HistorySearchScope(sources: [RecordingSource.mac.rawValue]), limit: 2)
        XCTAssertEqual(overview.total, 3)
        XCTAssertEqual(overview.hits.count, 2)
        XCTAssertFalse(overview.hits.contains { $0.recordID == old })
    }

    func testATitleBringsTheBestPassageOfItsRecord() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        try await index.upsert([
            record(title: "Kick-off Druckerei", passages: [passage("Wir fangen pünktlich an."), passage("Anna bestellt die Plakate.")]),
        ])

        // Without a matching passage the record's first one stands for it.
        let byTitle = try await index.search(words: ["Druckerei"])
        XCTAssertEqual(byTitle.map(\.ordinals), [0...0])
        XCTAssertEqual(byTitle.first?.title, "Kick-off Druckerei")
        let byTitleAndText = try await index.search(words: ["Druckerei", "Plakate"])
        XCTAssertEqual(byTitleAndText.map(\.ordinals), [1...1])
    }

    func testWordsThatMostPassagesHoldAreLeftOutOfALargeIndex() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let posters = UUID()
        var records = (0..<600).map { number in
            record(at: TestClock.date(2026, 1, 1).addingTimeInterval(Double(number)), passages: [passage("Termin Nummer \(number)")])
        }
        records.append(record(posters, passages: [passage("Termin für die Plakate")]))
        // Each passage counts once, however many forms of the word it holds.
        let budget = (0..<40).map { _ in record(passages: [passage("Budget, Budgets und Budgetierung")]) }
        try await index.upsert(records + budget)

        let found = try await index.search(words: ["Termin", "Plakate"])
        XCTAssertEqual(found.map(\.recordID), [posters])
        let budgetFound = try await index.search(words: ["Budget", "Plakate"])
        XCTAssertEqual(Set(budgetFound.map(\.recordID)), Set(budget.map(\.id) + [posters]))
        // A question that has only such words still finds something.
        let common = try await index.search(words: ["Termin"], limit: 10)
        XCTAssertEqual(common.count, 10)
    }

    func testASearchForTheLastTimeKeepsTheNewestMatch() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let records = (0..<100).map { day in
            record(at: TestClock.date(2026, 1, 1).addingTimeInterval(Double(day) * 86_400), passages: [passage("Heizung")])
        }
        try await index.upsert(records)

        let found = try await index.search(words: ["Heizung"], limit: 10, includingNewest: true)
        XCTAssertTrue(found.map(\.recordID).contains(records[99].id))
    }

    func testASearchForTheLastTimeKeepsTheNewestTitle() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let records = (0..<30).map { day in
            record(
                at: TestClock.date(2026, 1, 1).addingTimeInterval(Double(day) * 86_400),
                title: "Heizung", passages: [passage("Notiz")]
            )
        }
        try await index.upsert(records)

        let found = try await index.search(words: ["Heizung"], includingNewest: true)
        XCTAssertTrue(found.map(\.recordID).contains(records[29].id))
    }

    func testOneLongRecordDoesNotCrowdOutTheOthersInPartsOfWords() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let older = record(at: TestClock.date(2026, 11, 1), passages: [passage("Kinderzahnarzt")])
        let newer = record(passages: (0..<25).map { _ in passage("Kinderzahnarzt") })
        try await index.upsert([older, newer])

        let found = try await index.search(words: ["Zahnarzt"])
        XCTAssertEqual(Set(found.map(\.recordID)), [older.id, newer.id])
    }

    func testOneLongRecordDoesNotCrowdOutTheOthers() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let long = record(passages: (0..<80).map { _ in passage("Heizung Heizung") })
        let others = (0..<15).map { _ in record(passages: [passage("Die Heizung und noch einiges mehr")]) }
        try await index.upsert([long] + others)

        let found = try await index.search(words: ["Heizung"])
        XCTAssertEqual(Set(found.map(\.recordID)), Set(([long] + others).map(\.id)))
    }

    func testTheVocabularyNamesSpeakersAppsAndDomainsAndFollowsTheIndex() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let slack = HistorySearchVocabulary.App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        try await index.upsert([
            record(passages: [passage("Hallo", speakers: ["Anna", "Ben"]), passage("Tschüss", speakers: ["Ben"])]),
            record(app: slack, domain: "github.com", passages: [passage("Notiz")]),
        ])
        var vocabulary = try await index.vocabulary()
        XCTAssertEqual(vocabulary, HistorySearchVocabulary(speakers: ["Anna", "Ben"], apps: [slack], domains: ["github.com"]))

        try await index.upsert([record(passages: [passage("Guten Tag", speakers: ["Carla"])])])
        vocabulary = try await index.vocabulary()
        XCTAssertEqual(vocabulary.speakers, ["Anna", "Ben", "Carla"])
    }

    func testHitsOfOneRecordAreLimitedAndNeighboursAreJoined() {
        let long = UUID(), other = UUID()
        func hit(_ record: UUID, _ ordinal: Int, score: Double, daysAgo: Double = 1) -> HistorySearchHit {
            HistorySearchHit(
                recordID: record, recordedAt: TestClock.now.addingTimeInterval(-daysAgo * 86_400), source: "mac",
                ordinals: ordinal...ordinal,
                passage: HistoryPassage(
                    kind: .transcript, text: "Text \(ordinal)", startSeconds: Double(ordinal) * 10,
                    endSeconds: Double(ordinal) * 10 + 10, utf16Range: ordinal * 6..<ordinal * 6 + 6
                ),
                score: score
            )
        }
        let hits = [hit(long, 2, score: 0.9), hit(long, 3, score: 0.8), hit(other, 0, score: 0.7), hit(long, 7, score: 0.6), hit(long, 4, score: 0.5)]

        let arranged = HistoryRetriever.arranged(hits, limit: 10, prefersNewest: false, now: TestClock.now)

        // The fourth passage of the long record is left out, and passages 2 and 3 are one hit.
        XCTAssertEqual(arranged.map(\.recordID), [long, other, long])
        XCTAssertEqual(arranged.map(\.ordinals), [2...3, 0...0, 7...7])
        XCTAssertEqual(arranged[0].passage.text, "Text 2 Text 3")
        XCTAssertEqual(arranged[0].passage.startSeconds, 20)
        XCTAssertEqual(arranged[0].passage.endSeconds, 40)
        XCTAssertEqual(arranged[0].passage.utf16Range, 12..<24)

        // Of two equal matches the newer one is ahead; "the last time" sorts by date alone.
        let old = hit(long, 0, score: 0.5, daysAgo: 300), new = hit(other, 0, score: 0.5, daysAgo: 2)
        let better = hit(long, 5, score: 0.9, daysAgo: 300)
        XCTAssertEqual(
            HistoryRetriever.arranged([old, new], limit: 10, prefersNewest: false, now: TestClock.now).map(\.recordID),
            [other, long]
        )
        XCTAssertEqual(
            HistoryRetriever.arranged([better, new], limit: 10, prefersNewest: true, now: TestClock.now).map(\.recordID),
            [other, long]
        )
    }

    func testARecordThatHistoryNoLongerHasIsLeftOut() async throws {
        let (index, directory) = try makeIndex()
        defer { TestSupport.remove(directory) }
        let kept = UUID(), deleted = UUID()
        try await index.upsert([
            record(kept, passages: [passage("Budget für den Druck")]),
            record(deleted, passages: [passage("Budget für die Messe")]),
        ])
        let retriever = HistoryRetriever(index: index) { $0.subtracting([deleted]) }

        let lookup = try await retriever.retrieve(HistorySearchPlan(question: "", keywords: ["Budget"]))
        XCTAssertEqual(lookup.hits.map(\.recordID), [kept])
        XCTAssertNil(lookup.recordCount)
        let overview = try await retriever.retrieve(HistorySearchPlan(question: ""))
        XCTAssertEqual(overview.hits.map(\.recordID), [kept])
        XCTAssertEqual(overview.recordCount, 2)
    }

    @MainActor
    func testTheReaderTellsWhichRecordsHistoryStillHas() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let history = HistoryService(appSupportDirectory: directory)
        let kept = UUID(), deleted = UUID()
        for id in [kept, deleted] {
            XCTAssertTrue(history.addRecord(
                id: id, rawText: "Text", finalText: "Text", appName: "Notes", appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 3, language: "en", engineUsed: "test"
            ))
        }
        history.deleteRecord(withID: deleted)

        XCTAssertEqual(try history.searchRecordReader.existingIDs(among: [kept, deleted, UUID()]), [kept])
    }
}

/// Runs the questions of `Fixtures/HistoryAsk` against a synthetic History of
/// 200 records and counts how often the expected record is among the first
/// eight hits. iOS runs the same files, without the questions marked "mac".
final class HistoryRetrievalEvaluationTests: XCTestCase {
    private struct Corpus: Decodable {
        struct Record: Decodable {
            var id: String
            var daysAgo: Int
            var time: String
            var source: String
            var language: String
            var title: String?
            var app: String?
            var bundleID: String?
            var domain: String?
            var text: String?
            var turns: [[String]]?
            var result: String?
            var resultTitle: String?
        }

        var referenceDate: Date
        var timeZone: String
        var records: [Record]
    }

    private struct Question: Decodable {
        var question: String
        var expected: [String]
        /// "meaning" marks questions in other words than the recording, which
        /// full-text search mostly cannot answer.
        var kind: String
    }

    private static func id(_ name: String) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", Int(name.dropFirst()) ?? 0))!
    }

    private static func fixture<T: Decodable>(_ name: String) throws -> T {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/HistoryAsk/\(name).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private static func searchRecord(_ record: Corpus.Record, now: Date, calendar: Calendar) -> HistorySearchRecord {
        let time = record.time.split(separator: ":").compactMap { Int($0) }
        let day = calendar.date(byAdding: .day, value: -record.daysAgo, to: calendar.startOfDay(for: now)) ?? now
        let date = calendar.date(bySettingHour: time[0], minute: time[1], second: 0, of: day) ?? day
        var passages: [HistoryPassage] = []
        var duration = 0.0
        if let turns = record.turns {
            passages = HistoryPassageChunker.passages(ofSpeakerSegments: turns.map { turn in
                let start = duration
                duration += Double(turn[1].count) / 15
                return HistoryPassageSpeakerSegment(speaker: turn[0], text: turn[1], start: start, end: duration)
            })
        } else if let text = record.text {
            passages = HistoryPassageChunker.passages(of: text)
            duration = Double(text.count) / 15
        }
        if let result = record.result {
            passages += HistoryPassageChunker.passages(of: result, kind: .result)
        }
        return HistorySearchRecord(
            id: id(record.id), recordedAt: date, source: record.source, originDeviceID: "device",
            language: record.language, durationSeconds: duration, title: record.resultTitle ?? record.title,
            appName: record.app, bundleID: record.bundleID, domain: record.domain, versionID: nil,
            fingerprint: HistorySearchFingerprint(version: "1", contentHash: "1"), passages: passages
        )
    }

    func testTheExpectedRecordIsAmongTheFirstEightHits() async throws {
        let corpus: Corpus = try Self.fixture("corpus")
        let questions: [Question] = try Self.fixture("questions")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: corpus.timeZone))
        calendar.firstWeekday = 2

        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let index = HistorySearchIndex(directory: directory.appendingPathComponent("index", isDirectory: true))
        try await index.upsert(corpus.records.map {
            Self.searchRecord($0, now: corpus.referenceDate, calendar: calendar)
        })
        let planner = AskHistoryPlanner(
            vocabulary: try await index.vocabulary(), now: corpus.referenceDate, calendar: calendar
        )
        let retriever = HistoryRetriever(index: index) { $0 }

        var asked: [Bool: Int] = [:]
        var found: [Bool: Int] = [:]
        var missed: [String] = []
        for question in questions {
            let retrieval = try await retriever.retrieve(
                planner.plan(for: question.question), limit: 8, now: corpus.referenceDate
            )
            let usesTheWords = question.kind != "meaning"
            asked[usesTheWords, default: 0] += 1
            if Set(question.expected.map(Self.id)).isSubset(of: retrieval.hits.map(\.recordID)) {
                found[usesTheWords, default: 0] += 1
            } else if usesTheWords {
                missed.append(question.question)
            }
        }

        // Measured on macOS 27.2: 80 of 80 questions in the recording's words
        // and 7 of 21 in other words. The limits leave room for the system's
        // word tagger, which differs between macOS versions.
        let inWords = Double(found[true, default: 0]) / Double(max(asked[true, default: 0], 1))
        let overall = Double(found.values.reduce(0, +)) / Double(max(questions.count, 1))
        XCTAssertGreaterThanOrEqual(inWords, 0.95, "missed: \(missed)")
        XCTAssertGreaterThanOrEqual(overall, 0.8)
    }
}
