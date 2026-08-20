import Combine
import Foundation

@MainActor
final class HistorySyncPreferences: ObservableObject {
    private enum Keys {
        static let enabled = "premiumSync.historyEnabled"
        static let audioEnabled = "premiumSync.historyAudioEnabled"
        static let audioReceiveSince = "premiumSync.historyAudioReceiveSince"
        static let explicitDeletions = "premiumSync.historyExplicitDeletions"
        static let suppressedRecordIDs = "premiumSync.historySuppressedRecordIDs"
        static let deviceID = "premiumSync.historyDeviceID"
    }

    private let defaults: UserDefaults
    let deviceID: String

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var isAudioEnabled: Bool {
        didSet {
            defaults.set(isAudioEnabled, forKey: Keys.audioEnabled)
            if isAudioEnabled {
                if !oldValue || audioReceiveSince == nil {
                    let enabledAt = Date()
                    audioReceiveSince = enabledAt
                    defaults.set(enabledAt, forKey: Keys.audioReceiveSince)
                }
            } else {
                audioReceiveSince = nil
                defaults.removeObject(forKey: Keys.audioReceiveSince)
            }
        }
    }
    @Published private(set) var audioReceiveSince: Date?
    @Published private(set) var explicitDeletions: [String: Date]
    @Published private(set) var suppressedRecordIDs: [String: Date]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDeviceID = defaults.string(forKey: Keys.deviceID)
        deviceID = storedDeviceID ?? UUID().uuidString.lowercased()
        if storedDeviceID == nil {
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let storedAudioEnabled = defaults.bool(forKey: Keys.audioEnabled)
        isAudioEnabled = storedAudioEnabled
        if storedAudioEnabled {
            if let stored = defaults.object(forKey: Keys.audioReceiveSince) as? Date {
                audioReceiveSince = stored
            } else {
                let enabledAt = Date()
                audioReceiveSince = enabledAt
                defaults.set(enabledAt, forKey: Keys.audioReceiveSince)
            }
        } else {
            audioReceiveSince = nil
        }
        explicitDeletions = Self.decode(
            [String: Date].self,
            from: defaults.data(forKey: Keys.explicitDeletions)
        ) ?? [:]
        let storedSuppressions = defaults.data(forKey: Keys.suppressedRecordIDs)
        if let timestamped = Self.decode([String: Date].self, from: storedSuppressions) {
            suppressedRecordIDs = timestamped
        } else {
            suppressedRecordIDs = Dictionary(
                uniqueKeysWithValues: (Self.decode([String].self, from: storedSuppressions) ?? [])
                    .map { ($0, Date()) }
            )
        }
        pruneExpiredJournals()
    }

    func shouldReceiveSynchronizedAudio(createdAt: Date) -> Bool {
        guard isAudioEnabled, let audioReceiveSince else { return false }
        // Allow a small cross-device clock and sync-start tolerance without backfilling old audio.
        return createdAt >= audioReceiveSince.addingTimeInterval(-5 * 60)
    }

    func recordExplicitDeletion(_ recordID: UUID, at date: Date = Date()) {
        recordExplicitDeletions([recordID], at: date)
    }

    func recordExplicitDeletions(_ recordIDs: [UUID], at date: Date = Date()) {
        for recordID in recordIDs {
            let key = recordID.uuidString.lowercased()
            explicitDeletions[key] = date
            suppressedRecordIDs.removeValue(forKey: key)
        }
        persistJournal()
    }

    func recordRetentionPrune(_ recordID: UUID, at date: Date = Date()) {
        recordRetentionPrunes([recordID], at: date)
    }

    func recordRetentionPrunes(_ recordIDs: [UUID], at date: Date = Date()) {
        for recordID in recordIDs {
            suppressedRecordIDs[recordID.uuidString.lowercased()] = date
        }
        persistJournal()
    }

    func isSuppressed(_ recordID: UUID) -> Bool {
        suppressedRecordIDs[recordID.uuidString.lowercased()] != nil
    }

    func restoreSuppressedHistory() {
        suppressedRecordIDs.removeAll()
        persistJournal()
    }

    func removeDeletion(_ recordID: UUID) {
        explicitDeletions.removeValue(forKey: recordID.uuidString.lowercased())
        persistJournal()
    }

    private func pruneExpiredJournals(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        explicitDeletions = explicitDeletions.filter { $0.value >= cutoff }
        suppressedRecordIDs = suppressedRecordIDs.filter { $0.value >= cutoff }
        persistJournal()
    }

    private func persistJournal() {
        let encoder = JSONEncoder()
        guard let deletionsData = try? encoder.encode(explicitDeletions),
              let suppressionsData = try? encoder.encode(suppressedRecordIDs) else {
            return
        }
        defaults.set(deletionsData, forKey: Keys.explicitDeletions)
        defaults.set(suppressionsData, forKey: Keys.suppressedRecordIDs)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
