import Foundation
import os
import TypeWhisperPluginSDK

/// The LLM requests behind a history entry's text: which provider and model
/// ran and the token counts the providers reported. Counts are sums of what
/// the providers reported, never estimates.
///
/// Every request TypeWhisper sent for the text counts, including fallback
/// attempts, empty-result retries, and workflow segments processed during
/// recording, as long as it returned text or reported token counts. Requests
/// to the same provider and model are summed into one entry.
///
/// An empty `entries` list records that the text was made without an LLM,
/// for example after a re-transcription without a workflow replaced it.
struct HistoryLLMUsage: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// The provider's stable ID: the plugin's LLM provider ID, or `appleIntelligence`.
        var providerId: String
        /// The provider's name when the request ran, for display on every device.
        var providerName: String?
        /// The model that answered, or the requested model when the provider named none.
        var model: String?
        /// Requests to this provider and model.
        var requestCount: Int
        /// Sum of the reported input tokens; nil when no request reported them.
        var inputTokens: Int?
        /// Sum of the reported output tokens; nil when no request reported them.
        var outputTokens: Int?

        init(
            providerId: String,
            providerName: String? = nil,
            model: String? = nil,
            requestCount: Int = 1,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil
        ) {
            self.providerId = providerId
            self.providerName = providerName
            self.model = model
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }

        /// Lenient: payloads of other devices must not fail a whole sync
        /// operation, so bad counts are dropped instead of failing the decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            providerId = try container.decode(String.self, forKey: .providerId)
            providerName = (try? container.decodeIfPresent(String.self, forKey: .providerName)) ?? nil
            model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
            let requests = (try? container.decodeIfPresent(Int.self, forKey: .requestCount)) ?? nil
            requestCount = max(1, requests ?? 1)
            inputTokens = Self.validCount((try? container.decodeIfPresent(Int.self, forKey: .inputTokens)) ?? nil)
            outputTokens = Self.validCount((try? container.decodeIfPresent(Int.self, forKey: .outputTokens)) ?? nil)
        }

        private static func validCount(_ value: Int?) -> Int? {
            value.flatMap { $0 >= 0 ? $0 : nil }
        }

        /// The name to show: the recorded name, or the provider ID.
        var displayProviderName: String {
            let name = providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? providerId : name
        }
    }

    var entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? container.decodeIfPresent([LenientEntry].self, forKey: .entries)) ?? nil
        entries = (decoded ?? []).compactMap(\.entry).filter {
            !$0.providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Sum of the reported input tokens of all entries; nil when none reported them.
    var inputTokens: Int? { Self.sum(entries.map(\.inputTokens)) }
    /// Sum of the reported output tokens of all entries; nil when none reported them.
    var outputTokens: Int? { Self.sum(entries.map(\.outputTokens)) }
    var requestCount: Int { entries.reduce(0) { $0 + $1.requestCount } }
    var hasTokenCounts: Bool { inputTokens != nil || outputTokens != nil }

    /// Sums the counts that are known; nil when none is.
    static func sum(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0) { $0.addingReportingOverflow($1).overflow ? Int.max : $0 + $1 }
    }

    /// Stored and synchronized as JSON with sorted keys, so equal usage always
    /// has equal bytes.
    func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data?) -> HistoryLLMUsage? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HistoryLLMUsage.self, from: data)
    }

    /// Adds one request's reports to the matching entry, or appends an entry.
    /// A request without reports counts once with unknown token counts.
    mutating func addRequest(
        providerId: String,
        providerName: String?,
        requestedModel: String?,
        reports: [PluginLLMUsage]
    ) {
        guard !reports.isEmpty else {
            add(Entry(providerId: providerId, providerName: providerName, model: requestedModel))
            return
        }
        for report in reports {
            add(Entry(
                providerId: providerId,
                providerName: providerName,
                model: report.model ?? requestedModel,
                inputTokens: report.inputTokens,
                outputTokens: report.outputTokens
            ))
        }
    }

    /// Adds the requests of another usage, entry by entry.
    mutating func add(_ other: HistoryLLMUsage) {
        for entry in other.entries {
            add(entry)
        }
    }

    private mutating func add(_ entry: Entry) {
        guard let index = entries.firstIndex(where: {
            $0.providerId == entry.providerId && $0.model == entry.model
        }) else {
            entries.append(entry)
            return
        }
        entries[index].requestCount += entry.requestCount
        entries[index].inputTokens = Self.sum([entries[index].inputTokens, entry.inputTokens])
        entries[index].outputTokens = Self.sum([entries[index].outputTokens, entry.outputTokens])
        if entries[index].providerName == nil {
            entries[index].providerName = entry.providerName
        }
    }

    /// Skips entries another device wrote in a shape this build cannot read.
    private struct LenientEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }
}

/// Collects the LLM requests of one piece of work, such as the post-processing
/// of one dictation. `PromptProcessingService` adds every provider request it
/// makes while a ledger is installed as `current`, also from child tasks and
/// unstructured tasks that inherit it.
final class LLMUsageLedger: Sendable {
    @TaskLocal static var current: LLMUsageLedger?

    private let state = OSAllocatedUnfairLock(initialState: HistoryLLMUsage(entries: []))

    init() {}

    /// The requests so far; nil before the first one.
    var usage: HistoryLLMUsage? {
        state.withLock { $0.entries.isEmpty ? nil : $0 }
    }

    func recordRequest(
        providerId: String,
        providerName: String?,
        requestedModel: String?,
        reports: [PluginLLMUsage]
    ) {
        state.withLock {
            $0.addRequest(
                providerId: providerId,
                providerName: providerName,
                requestedModel: requestedModel,
                reports: reports
            )
        }
    }

    /// Adds the requests another ledger collected, for example the segments a
    /// workflow processed while the user was still speaking.
    func merge(_ other: LLMUsageLedger?) {
        guard let other, other !== self, let usage = other.usage else { return }
        state.withLock { $0.add(usage) }
    }
}
