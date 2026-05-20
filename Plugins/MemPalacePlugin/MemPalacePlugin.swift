import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

private let logger = Logger(subsystem: "com.mempalace.memory", category: "plugin")

@objc(MemPalacePlugin)
public final class MemPalacePlugin: NSObject, TypeWhisperPlugin, MemoryStoragePlugin, @unchecked Sendable {
    public static let pluginId = "com.mempalace.memory"
    public static let pluginName = "MemPalace"

    public var storageName: String {
        switch config.deployment {
        case .cloud: return "MemPalace Cloud"
        case .selfHosted: return "MemPalace (Self-Hosted)"
        }
    }

    public var isReady: Bool {
        host != nil && client != nil && config.isValid
    }

    public var memoryCount: Int {
        // Snapshot updated after every mutation. Avoids sync-from-actor blocking.
        cachedMemoryCount
    }

    private var cachedMemoryCount: Int = 0
    fileprivate var host: HostServices?
    fileprivate var config: MemPalaceConfig = .default
    fileprivate var apiKey: String?
    fileprivate var client: MemPalaceMCPClient?
    fileprivate var sidecar: SidecarStore?
    fileprivate var queue: OfflineQueue?
    private var queueDrainTask: Task<Void, Never>?
    private var reconcileCallCounter: Int = 0
    private let reconcileEveryNCalls = 10
    private let reconcileBatchSize = 8
    private var clientFactory: (URL, String) -> MemPalaceMCPClient = { url, key in
        MemPalaceMCPClient(baseURL: url, apiKey: key)
    }

    public required override init() {
        super.init()
    }

    /// Test seam.
    init(clientFactory: @escaping (URL, String) -> MemPalaceMCPClient) {
        self.clientFactory = clientFactory
        super.init()
    }

    public func activate(host: HostServices) {
        self.host = host
        self.config = Self.loadConfig(from: host) ?? .default
        self.apiKey = host.loadSecret(key: MemPalaceUserDefaultsKey.secretAPIKey)
        let sidecarURL = host.pluginDataDirectory.appendingPathComponent("sidecar.json")
        let store = SidecarStore(url: sidecarURL)
        self.sidecar = store
        // Prime cached count synchronously from disk so the host UI sees a
        // consistent value from the first paint, not 0 → real-count flicker.
        cachedMemoryCount = SidecarStore.countOnDisk(url: sidecarURL)

        let queueURL = host.pluginDataDirectory.appendingPathComponent("queue.json")
        let q = OfflineQueue(url: queueURL)
        self.queue = q

        rebuildClient()

        // Background drain loop — retry queued stores while client + config valid.
        queueDrainTask?.cancel()
        queueDrainTask = Task { [weak self] in
            await self?.runQueueDrainLoop(queue: q)
        }
    }

    public func deactivate() {
        queueDrainTask?.cancel()
        queueDrainTask = nil
        // Synchronous flush: block until persist completes so a host quit
        // immediately after deactivate() does not lose the last mutations.
        if let sidecar, let queue = self.queue {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await sidecar.flush()
                await queue.flush()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        host = nil
        client = nil
        apiKey = nil
        sidecar = nil
        queue = nil
        cachedMemoryCount = 0
    }

    public var settingsView: AnyView? {
        AnyView(MemPalaceSettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    public func store(_ entries: [MemoryEntry]) async throws {
        guard let sidecar, let queue else { throw MemPalaceMCPError.missingAPIKey }
        guard config.isValid else { throw MemPalaceMCPError.toolError("invalid config") }

        // If client is offline (no API key, invalid URL): enqueue all and return.
        // The drain loop will replay when client becomes ready.
        guard let client else {
            for entry in entries {
                await queue.enqueue(entry, wing: config.wing, room: config.room)
            }
            logger.info("store: client unavailable, enqueued \(entries.count) memories")
            return
        }

        var firstError: Error?
        for entry in entries {
            do {
                let drawerId = try await client.addDrawer(
                    content: entry.content,
                    wing: config.wing,
                    room: config.room,
                    sourceFile: MemPalaceSourceFile.encode(entry.id)
                )
                await sidecar.upsert(entry, drawerId: drawerId)
            } catch {
                // Network / API error: enqueue for retry, keep trying remaining entries.
                logger.notice("store failed for entry \(entry.id.uuidString); enqueued: \(error.localizedDescription)")
                await queue.enqueue(entry, wing: config.wing, room: config.room)
                if firstError == nil { firstError = error }
            }
        }
        await sidecar.flush()
        cachedMemoryCount = await sidecar.count
        host?.notifyCapabilitiesChanged()

        // Surface the first error to the host so the user gets a signal, but
        // the memory is not lost — it lives in the queue.
        if let error = firstError { throw error }
    }

    public func search(_ query: MemoryQuery) async throws -> [TypeWhisperPluginSDK.MemorySearchResult] {
        guard let client, let sidecar else { return [] }
        let hits = try await client.search(text: query.text, wing: config.wing, limit: query.maxResults)

        var results: [TypeWhisperPluginSDK.MemorySearchResult] = []
        for hit in hits {
            guard let uuid = MemPalaceSourceFile.decode(hit.source_file) else {
                logger.debug("search hit dropped: source_file did not decode (\(hit.source_file ?? "nil"))")
                continue
            }
            guard var record = await sidecar.record(for: uuid) else { continue }
            guard record.entry.confidence >= query.minConfidence else { continue }
            if let types = query.types, !types.contains(record.entry.type) { continue }

            record.entry.lastAccessedAt = Date()
            record.entry.accessCount += 1
            await sidecar.upsert(record.entry, drawerId: record.drawerId)

            let score = hit.similarity ?? max(0, 1.0 - (hit.distance ?? 0))
            results.append(TypeWhisperPluginSDK.MemorySearchResult(entry: record.entry, relevanceScore: score))
        }
        await sidecar.flush()
        return results
    }

    public func delete(_ ids: [UUID]) async throws {
        guard let client, let sidecar else { throw MemPalaceMCPError.missingAPIKey }

        // Codex fix: collect drawers safe to remove BEFORE mutating sidecar, so
        // batched UUIDs sharing a drawer_id only trigger one server-DELETE.
        var drawersToDelete: [String] = []
        var seenDrawers: Set<String> = []
        let idSet = Set(ids)

        for id in ids {
            guard let record = await sidecar.record(for: id) else { continue }
            if seenDrawers.contains(record.drawerId) { continue }
            seenDrawers.insert(record.drawerId)

            let remainingOwners = await sidecar.idsPointing(at: record.drawerId).filter { !idSet.contains($0) }
            if remainingOwners.isEmpty {
                drawersToDelete.append(record.drawerId)
            }
        }

        for drawerId in drawersToDelete {
            try await client.deleteDrawer(drawerId)
        }
        for id in ids {
            await sidecar.remove(id)
        }
        await sidecar.flush()
        cachedMemoryCount = await sidecar.count
        host?.notifyCapabilitiesChanged()
    }

    public func update(_ entry: MemoryEntry) async throws {
        guard let client, let sidecar else { return }
        guard let record = await sidecar.record(for: entry.id) else { return }
        try await client.updateDrawer(record.drawerId, content: entry.content)
        await sidecar.upsert(entry, drawerId: record.drawerId)
        await sidecar.flush()
    }

    public func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        guard let sidecar else { return [] }

        // Lazy reconcile every Nth call: drop sidecar entries whose drawer
        // disappeared on the server (e.g. user deleted directly in MemPalace UI).
        reconcileCallCounter += 1
        if reconcileCallCounter % reconcileEveryNCalls == 0 {
            Task { [weak self] in
                await self?.runLazyReconcile()
            }
        }

        return await sidecar.entries(offset: offset, limit: limit)
    }

    public func deleteAll() async throws {
        guard let client, let sidecar else { throw MemPalaceMCPError.missingAPIKey }
        let drawerIds = await sidecar.allDrawerIds()
        for drawerId in drawerIds {
            try? await client.deleteDrawer(drawerId)
        }
        await sidecar.clear()
        await sidecar.flush()
        cachedMemoryCount = 0
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Settings hooks

    func currentConfig() -> MemPalaceConfig { config }

    func updateConfig(_ newConfig: MemPalaceConfig) -> Bool {
        guard newConfig.isValid else { return false }
        config = newConfig
        if let host, let data = try? JSONEncoder().encode(newConfig),
           let json = String(data: data, encoding: .utf8) {
            host.setUserDefault(json, forKey: MemPalaceUserDefaultsKey.config)
        }
        rebuildClient()
        host?.notifyCapabilitiesChanged()
        return true
    }

    func currentAPIKey() -> String? { apiKey }

    func updateAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty {
            apiKey = nil
            // Keychain "clear" = store empty (HostServices has no delete API).
            try? host?.storeSecret(key: MemPalaceUserDefaultsKey.secretAPIKey, value: "")
        } else {
            apiKey = trimmed
            try? host?.storeSecret(key: MemPalaceUserDefaultsKey.secretAPIKey, value: trimmed)
        }
        rebuildClient()
        host?.notifyCapabilitiesChanged()
    }

    func taxonomyClient() -> MemPalaceMCPClient? { client }

    func listAllSidecarEntries() async -> [MemoryEntry] {
        guard let sidecar else { return [] }
        return await sidecar.allEntries()
    }

    // MARK: - Internals

    private func rebuildClient() {
        guard let url = config.resolvedBaseURL,
              let key = apiKey, !key.isEmpty,
              config.isValid
        else {
            client = nil
            return
        }
        client = clientFactory(url, key)
    }

    private static func loadConfig(from host: HostServices) -> MemPalaceConfig? {
        guard let raw = host.userDefault(forKey: MemPalaceUserDefaultsKey.config) as? String,
              let data = raw.data(using: .utf8),
              let config = try? JSONDecoder().decode(MemPalaceConfig.self, from: data)
        else { return nil }
        return config
    }

    // MARK: - Offline drain loop

    private func runQueueDrainLoop(queue: OfflineQueue) async {
        // Exponential backoff between drain attempts: 5s → 10s → 20s → ... cap 5min.
        var delaySeconds: UInt64 = 5
        while !Task.isCancelled {
            // Sleep first to give activate() time to settle.
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            if Task.isCancelled { break }

            guard let client, let sidecar else {
                delaySeconds = min(delaySeconds * 2, 300)
                continue
            }
            if await queue.isEmpty {
                delaySeconds = 30  // idle poll
                continue
            }

            let batch = await queue.nextBatch(limit: 5)
            var anyProgress = false
            for item in batch {
                do {
                    let drawerId = try await client.addDrawer(
                        content: item.entry.content,
                        wing: item.wing,
                        room: item.room,
                        sourceFile: MemPalaceSourceFile.encode(item.entry.id)
                    )
                    await sidecar.upsert(item.entry, drawerId: drawerId)
                    await queue.remove(item.entry.id)
                    anyProgress = true
                } catch {
                    logger.notice("queue retry failed for \(item.entry.id.uuidString) attempt \(item.attemptCount): \(error.localizedDescription)")
                    // Leave in queue; loop will retry after backoff.
                    break
                }
            }
            if anyProgress {
                await sidecar.flush()
                cachedMemoryCount = await sidecar.count
                host?.notifyCapabilitiesChanged()
                delaySeconds = 5  // reset backoff on success
            } else {
                delaySeconds = min(delaySeconds * 2, 300)
            }
        }
    }

    // MARK: - Lazy reconcile

    private func runLazyReconcile() async {
        guard let client, let sidecar else { return }
        // Sample N random drawer ids from sidecar; if MemPalace says they don't
        // exist, drop the sidecar entries (user deleted via MemPalace UI).
        let allIds = await sidecar.allDrawerIds()
        guard !allIds.isEmpty else { return }
        let sample = allIds.shuffled().prefix(reconcileBatchSize)
        var toDropDrawers: [String] = []
        for drawerId in sample {
            do {
                let exists = try await client.drawerExists(drawerId)
                if !exists { toDropDrawers.append(drawerId) }
            } catch {
                // Network / auth error: bail entirely, retry next time.
                return
            }
        }
        guard !toDropDrawers.isEmpty else { return }

        for drawerId in toDropDrawers {
            let uuids = await sidecar.idsPointing(at: drawerId)
            for uuid in uuids {
                await sidecar.remove(uuid)
            }
        }
        await sidecar.flush()
        cachedMemoryCount = await sidecar.count
        logger.info("reconcile dropped \(toDropDrawers.count) stale drawer mappings")
        host?.notifyCapabilitiesChanged()
    }
}
