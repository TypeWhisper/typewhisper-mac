import Foundation

/// What a search found for a plan.
struct HistoryRetrieval: Equatable, Sendable {
    /// Best first. For an overview, the first passage of each record, newest first.
    var hits: [HistorySearchHit]
    /// For an overview, the number of records in its scope, of which `hits`
    /// holds the newest.
    var recordCount: Int?
}

/// Finds the passages of History that a search plan asks for.
struct HistoryRetriever: Sendable {
    /// More passages of one record would crowd out the other records.
    static let passagesPerRecord = 3
    /// A passage recorded now ranks this much higher than a very old one.
    static let recencyBoost = 0.1
    static let recencyHalfLifeDays = 90.0

    let index: HistorySearchIndex
    /// The records among the given ones that History still has. The index
    /// hears of a deletion a moment after History, and a deleted record must
    /// never be quoted.
    let existingRecordIDs: @Sendable (Set<UUID>) async throws -> Set<UUID>

    init(index: HistorySearchIndex, existingRecordIDs: @escaping @Sendable (Set<UUID>) async throws -> Set<UUID>) {
        self.index = index
        self.existingRecordIDs = existingRecordIDs
    }

    init(index: HistorySearchIndex, reader: HistorySearchRecordReader) {
        self.init(index: index) { ids in
            try await Task.detached(priority: .userInitiated) { try reader.existingIDs(among: ids) }.value
        }
    }

    func retrieve(_ plan: HistorySearchPlan, limit: Int = 12, now: Date = Date()) async throws -> HistoryRetrieval {
        switch plan.intent {
        case .overview:
            let (hits, total) = try await index.newestRecords(in: plan.scope, limit: limit)
            return HistoryRetrieval(hits: try await existing(hits), recordCount: total)
        case .lookup:
            let hits = try await index.search(words: plan.keywords, names: plan.names, in: plan.scope)
            return HistoryRetrieval(
                hits: Self.arranged(try await existing(hits), limit: limit, prefersNewest: plan.prefersNewest, now: now)
            )
        }
    }

    private func existing(_ hits: [HistorySearchHit]) async throws -> [HistorySearchHit] {
        guard !hits.isEmpty else { return [] }
        let existing = try await existingRecordIDs(Set(hits.map(\.recordID)))
        return hits.filter { existing.contains($0.recordID) }
    }

    /// The hits a prompt can use: newer records slightly ahead, at most three
    /// passages per record, and neighbouring passages joined into one.
    static func arranged(
        _ hits: [HistorySearchHit], limit: Int, prefersNewest: Bool, now: Date
    ) -> [HistorySearchHit] {
        var boosted = hits
        for index in boosted.indices {
            let days = max(now.timeIntervalSince(boosted[index].recordedAt), 0) / 86_400
            boosted[index].score *= 1 + recencyBoost * pow(0.5, days / recencyHalfLifeDays)
        }
        let ranked = boosted.enumerated()
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .map(\.element)

        var counts: [UUID: Int] = [:]
        var joined: [HistorySearchHit] = []
        // In the order of a record's text, so neighbours meet.
        let kept = ranked.filter { hit in
            counts[hit.recordID, default: 0] += 1
            return counts[hit.recordID, default: 0] <= passagesPerRecord
        }
        .sorted { ($0.recordID.uuidString, $0.ordinals.lowerBound) < ($1.recordID.uuidString, $1.ordinals.lowerBound) }
        for hit in kept {
            if let last = joined.last, last.recordID == hit.recordID, last.passage.kind == hit.passage.kind,
               last.ordinals.upperBound + 1 == hit.ordinals.lowerBound {
                joined[joined.count - 1] = Self.joined(last, hit)
            } else {
                joined.append(hit)
            }
        }

        let ordered = joined.sorted { first, second in
            if prefersNewest, first.recordedAt != second.recordedAt { return first.recordedAt > second.recordedAt }
            if first.score != second.score { return first.score > second.score }
            return (first.recordID.uuidString, first.ordinals.lowerBound)
                < (second.recordID.uuidString, second.ordinals.lowerBound)
        }
        return Array(ordered.prefix(limit))
    }

    private static func joined(_ first: HistorySearchHit, _ second: HistorySearchHit) -> HistorySearchHit {
        var hit = first
        hit.ordinals = first.ordinals.lowerBound...second.ordinals.upperBound
        hit.score = max(first.score, second.score)
        // Speaker passages are lines of turns; other passages continue the text.
        let separator = first.passage.speakers.isEmpty && second.passage.speakers.isEmpty ? " " : "\n"
        hit.passage.text = first.passage.text + separator + second.passage.text
        for speaker in second.passage.speakers where !hit.passage.speakers.contains(speaker) {
            hit.passage.speakers.append(speaker)
        }
        hit.passage.startSeconds = [first.passage.startSeconds, second.passage.startSeconds].compactMap { $0 }.min()
        hit.passage.endSeconds = [first.passage.endSeconds, second.passage.endSeconds].compactMap { $0 }.max()
        if let range = first.passage.utf16Range, let next = second.passage.utf16Range, range.lowerBound <= next.upperBound {
            hit.passage.utf16Range = range.lowerBound..<next.upperBound
        } else {
            hit.passage.utf16Range = nil
        }
        return hit
    }
}
