import Foundation
import TypeWhisperPluginSDK

struct SidecarRecord: Codable {
    var entry: MemoryEntry
    var drawerId: String
}

/// Actor-isolated persistent store of UUID↔drawer_id mappings plus
/// TypeWhisper-specific MemoryEntry fields (confidence, accessCount,
/// lastAccessedAt, metadata, source, type, createdAt) that MemPalace
/// cannot round-trip via its API.
actor SidecarStore {
    private let url: URL
    private var records: [UUID: SidecarRecord] = [:]
    private var isDirty = false

    init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let array = try? JSONDecoder.memoryDecoder.decode([SidecarRecord].self, from: data) {
            for record in array {
                records[record.entry.id] = record
            }
        }
    }

    var count: Int { records.count }

    func upsert(_ entry: MemoryEntry, drawerId: String) {
        records[entry.id] = SidecarRecord(entry: entry, drawerId: drawerId)
        isDirty = true
    }

    func remove(_ id: UUID) {
        if records.removeValue(forKey: id) != nil {
            isDirty = true
        }
    }

    func record(for id: UUID) -> SidecarRecord? {
        records[id]
    }

    func entries(offset: Int, limit: Int) -> [MemoryEntry] {
        let sorted = records.values.map(\.entry).sorted { $0.createdAt > $1.createdAt }
        let safeOffset = max(0, offset)
        let safeLimit = max(0, limit)
        let start = min(safeOffset, sorted.count)
        let end = min(start + safeLimit, sorted.count)
        return Array(sorted[start..<end])
    }

    func allEntries() -> [MemoryEntry] {
        records.values.map(\.entry).sorted { $0.createdAt > $1.createdAt }
    }

    func allDrawerIds() -> [String] {
        Array(Set(records.values.map(\.drawerId)))
    }

    func idsPointing(at drawerId: String) -> [UUID] {
        records.values.filter { $0.drawerId == drawerId }.map(\.entry.id)
    }

    func idsForDrawers(_ drawerIds: Set<String>) -> [UUID] {
        records.values.filter { drawerIds.contains($0.drawerId) }.map(\.entry.id)
    }

    func clear() {
        records.removeAll()
        isDirty = true
    }

    /// Returns true if the on-disk file is consistent with in-memory state
    /// (either no-op because not dirty, or persist succeeded). Returns false
    /// only if a write was attempted and failed.
    @discardableResult
    func flush() -> Bool {
        guard isDirty else { return true }
        let array = Array(records.values)
        do {
            let data = try JSONEncoder.memoryEncoder.encode(array)
            try data.write(to: url, options: .atomic)
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    /// Synchronous helper: count records on disk without entering actor context.
    /// Used to prime UI badge in plugin activate() before any actor task runs.
    static nonisolated func countOnDisk(url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let array = try? JSONDecoder.memoryDecoder.decode([SidecarRecord].self, from: data)
        else { return 0 }
        return array.count
    }
}
