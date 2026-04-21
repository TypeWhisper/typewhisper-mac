import Foundation
import Combine

@MainActor
final class RecentTranscriptionStore: ObservableObject {
    enum Source: String, Equatable {
        case session
        case history
    }

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let finalText: String
        let timestamp: Date
        let appName: String?
        let appBundleIdentifier: String?
        let source: Source
    }

    @Published private(set) var sessionEntries: [Entry] = []

    private let maxSessionEntries: Int

    init(maxSessionEntries: Int = 20) {
        self.maxSessionEntries = maxSessionEntries
    }

    func recordTranscription(
        id: UUID,
        finalText: String,
        timestamp: Date = Date(),
        appName: String?,
        appBundleIdentifier: String?
    ) {
        let trimmedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        sessionEntries.removeAll { $0.id == id }
        sessionEntries.insert(
            Entry(
                id: id,
                finalText: trimmedText,
                timestamp: timestamp,
                appName: appName,
                appBundleIdentifier: appBundleIdentifier,
                source: .session
            ),
            at: 0
        )

        if sessionEntries.count > maxSessionEntries {
            sessionEntries.removeLast(sessionEntries.count - maxSessionEntries)
        }
    }

    func mergedEntries(historyRecords: [TranscriptionRecord], limit: Int = 12) -> [Entry] {
        let historyEntries = historyRecords.map {
            Entry(
                id: $0.id,
                finalText: $0.finalText,
                timestamp: $0.timestamp,
                appName: $0.appName,
                appBundleIdentifier: $0.appBundleIdentifier,
                source: .history
            )
        }

        let merged = (sessionEntries + historyEntries).sorted {
            if $0.timestamp == $1.timestamp {
                return $0.source == .session && $1.source == .history
            }
            return $0.timestamp > $1.timestamp
        }

        var seen = Set<UUID>()
        var deduped: [Entry] = []
        for entry in merged where seen.insert(entry.id).inserted {
            deduped.append(entry)
            if deduped.count == limit {
                break
            }
        }
        return deduped
    }
}
