import Foundation

/// Answers a question about what a part of History held, such as "Summarize
/// last week".
///
/// Cloud models get the beginning of every recording in one prompt and write
/// the overview from it. Apple Intelligence and the local models drop
/// recordings from such a prompt and, given summaries, mostly repeat them. For
/// them every recording is summarized on its own, and the overview is the list
/// of those summaries, newest first, each citing its recording. A summary is
/// kept in the index until its recording changes, so a second overview needs
/// no new ones.
@MainActor
struct AskHistoryOverview {
    /// More summaries would take minutes on a local model.
    static let maximumSummaries = 20

    let index: HistorySearchIndex
    let service: PromptProcessingService

    /// - Parameters:
    ///   - retrieval: The recordings of the plan's scope, newest first.
    ///   - progress: Called before each recording that has to be summarized,
    ///     with its number and how many there are.
    func answer(
        plan: HistorySearchPlan,
        retrieval: HistoryRetrieval,
        history: [AskHistoryTurn] = [],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        providerOverride: String? = nil,
        cloudModelOverride: String? = nil,
        effortOverride: String? = nil,
        progress: (_ number: Int, _ count: Int) -> Void = { _, _ in }
    ) async throws -> AskHistoryAnswer {
        guard let provider = service.historyOverviewProvider(providerOverride: providerOverride),
              provider.usesSummaries else {
            return try await service.answerHistoryQuestion(
                AskHistoryRequest(plan: plan, retrieval: retrieval, history: history, now: now, timeZone: timeZone),
                providerOverride: providerOverride, cloudModelOverride: cloudModelOverride,
                effortOverride: effortOverride
            )
        }

        let hits = Array(retrieval.hits.prefix(Self.maximumSummaries))
        var summaries: [UUID: (text: String, providerId: String)] = [:]
        for hit in hits {
            summaries[hit.recordID] = try await index.summary(ofRecord: hit.recordID)
        }
        let missing = hits.filter { summaries[$0.recordID] == nil }
        for (offset, hit) in missing.enumerated() {
            try Task.checkCancellation()
            progress(offset + 1, missing.count)
            // Deleted since the search.
            guard let transcript = try await index.transcript(ofRecord: hit.recordID),
                  !transcript.passages.isEmpty else { continue }
            let summary = try await service.summarizeHistoryRecording(
                passages: transcript.passages.map(\.text), title: hit.title, providerOverride: providerOverride,
                cloudModelOverride: cloudModelOverride, effortOverride: effortOverride
            )
            try await index.setSummary(
                summary.text, providerId: summary.providerId, ofRecord: hit.recordID, contentHash: transcript.contentHash
            )
            summaries[hit.recordID] = summary
        }

        var sources: [AskHistorySource] = []
        var lines: [String] = []
        // The providers that wrote the listed summaries, a fallback among them.
        var providerIds: [String] = []
        for hit in hits {
            guard let summary = summaries[hit.recordID] else { continue }
            var source = AskHistorySource(hit)
            source.text = summary.text
            source.startSeconds = nil
            sources.append(source)
            let text = summary.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            lines.append("- " + (hit.title.map { "\($0): " } ?? "") + text + " [\(sources.count)]")
            if !summary.providerId.isEmpty, !providerIds.contains(summary.providerId) {
                providerIds.append(summary.providerId)
            }
        }
        if providerIds.isEmpty { providerIds = [provider.providerId] }
        return AskHistoryAnswer(
            text: lines.joined(separator: "\n"),
            sources: sources,
            citedSources: Array(sources.indices.map { $0 + 1 }),
            providerId: providerIds[0],
            providerName: providerIds.map(service.displayName(for:)).joined(separator: ", "),
            omittedRecordCount: max((retrieval.recordCount ?? retrieval.hits.count) - sources.count, 0)
        )
    }
}
