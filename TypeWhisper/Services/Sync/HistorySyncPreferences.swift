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
    @Published private(set) var suppressedRecordIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedDeviceID = defaults.string(forKey: Keys.deviceID)
        deviceID = storedDeviceID ?? UUID().uuidString.lowercased()
        if storedDeviceID == nil {
            defaults.set(deviceID, forKey: Keys.deviceID)
        }
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let storedAudioEnabled = defaults.object(forKey: Keys.audioEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.audioEnabled)
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
        suppressedRecordIDs = Set(Self.decode(
            [String].self,
            from: defaults.data(forKey: Keys.suppressedRecordIDs)
        ) ?? [])
        pruneExpiredDeletions()
    }

    func shouldReceiveSynchronizedAudio(createdAt: Date) -> Bool {
        guard isAudioEnabled, let audioReceiveSince else { return false }
        // Allow a small cross-device clock and sync-start tolerance without backfilling old audio.
        return createdAt >= audioReceiveSince.addingTimeInterval(-5 * 60)
    }

    func recordExplicitDeletion(_ recordID: UUID, at date: Date = Date()) {
        explicitDeletions[recordID.uuidString.lowercased()] = date
        suppressedRecordIDs.remove(recordID.uuidString.lowercased())
        persistJournal()
    }

    func recordRetentionPrune(_ recordID: UUID) {
        suppressedRecordIDs.insert(recordID.uuidString.lowercased())
        persistJournal()
    }

    func isSuppressed(_ recordID: UUID) -> Bool {
        suppressedRecordIDs.contains(recordID.uuidString.lowercased())
    }

    func restoreSuppressedHistory() {
        suppressedRecordIDs.removeAll()
        persistJournal()
    }

    func removeDeletion(_ recordID: UUID) {
        explicitDeletions.removeValue(forKey: recordID.uuidString.lowercased())
        persistJournal()
    }

    private func pruneExpiredDeletions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        explicitDeletions = explicitDeletions.filter { $0.value >= cutoff }
        persistJournal()
    }

    private func persistJournal() {
        defaults.set(try? JSONEncoder().encode(explicitDeletions), forKey: Keys.explicitDeletions)
        defaults.set(
            try? JSONEncoder().encode(suppressedRecordIDs.sorted()),
            forKey: Keys.suppressedRecordIDs
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
