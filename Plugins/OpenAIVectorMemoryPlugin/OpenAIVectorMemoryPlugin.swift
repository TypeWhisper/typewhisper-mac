import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(OpenAIVectorMemoryPlugin)
final class OpenAIVectorMemoryPlugin: NSObject, TypeWhisperPlugin, MemoryStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.memory.openai-vector"
    static let pluginName = "OpenAI Vector Memory"

    var storageName: String { "OpenAI Vector Store" }
    var isReady: Bool { apiKey != nil && vectorStoreId != nil }
    var memoryCount: Int { localEntries.count }

    fileprivate var host: HostServices?
    fileprivate var apiKey: String?
    private var vectorStoreId: String?
    private var localEntries: [MemoryEntry] = []
    private var unsyncedIds: Set<UUID> = []
    private var fileMapping: [UUID: String] = [:]
    private var localEntriesURL: URL?
    private var fileMappingURL: URL?
    private let batchSize = 10

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        apiKey = host.loadSecret(key: "api-key")
        vectorStoreId = host.userDefault(forKey: "vectorStoreId") as? String
        localEntriesURL = host.pluginDataDirectory.appendingPathComponent("entries.json")
        fileMappingURL = host.pluginDataDirectory.appendingPathComponent("file-mapping.json")
        loadLocalData()

        if apiKey != nil && vectorStoreId == nil {
            Task { await createVectorStoreIfNeeded() }
        }
    }

    func deactivate() {
        // Capture all needed values before nilling
        let key = apiKey, storeId = vectorStoreId, pending = unsyncedIds
        let entriesToFlush = localEntries.filter { pending.contains($0.id) }
        if let key, let storeId, !entriesToFlush.isEmpty {
            Task { [weak self] in
                try? await self?.uploadAndAttach(entries: entriesToFlush, apiKey: key, storeId: storeId)
            }
        }
        host = nil
        apiKey = nil
    }

    var settingsView: AnyView? {
        AnyView(OpenAIVectorMemorySettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    func store(_ entries: [MemoryEntry]) async throws {
        localEntries.append(contentsOf: entries)
        for entry in entries { unsyncedIds.insert(entry.id) }
        saveLocalData()

        if unsyncedIds.count >= batchSize {
            try await flushUnsyncedEntries()
        }
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        guard let key = apiKey, let storeId = vectorStoreId else { return [] }

        let url = URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)/search")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query.text, "max_num_results": query.maxResults
        ])
        request.timeoutInterval = 15

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else {
            return fallbackLocalSearch(query)
        }

        let contentIndex = Dictionary(localEntries.map { ($0.content, $0) }, uniquingKeysWith: { first, _ in first })

        return results.compactMap { result -> MemorySearchResult? in
            guard let score = result["score"] as? Double,
                  let content = result["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { return nil }
            let entry = contentIndex[text] ?? MemoryEntry(content: text, type: .fact, confidence: score)
            return MemorySearchResult(entry: entry, relevanceScore: score)
        }
        .filter { $0.entry.confidence >= query.minConfidence }
    }

    func delete(_ ids: [UUID]) async throws {
        for id in ids {
            if let fileId = fileMapping.removeValue(forKey: id) {
                try? await deleteFile(fileId)
            }
            unsyncedIds.remove(id)
        }
        localEntries.removeAll { ids.contains($0.id) }
        saveLocalData()
    }

    func update(_ entry: MemoryEntry) async throws {
        guard let index = localEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        localEntries[index] = entry
        saveLocalData()
    }

    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        let sorted = localEntries.sorted { $0.createdAt > $1.createdAt }
        let start = min(offset, sorted.count)
        return Array(sorted[start..<min(start + limit, sorted.count)])
    }

    func deleteAll() async throws {
        if let storeId = vectorStoreId { try? await deleteVectorStore(storeId) }
        localEntries.removeAll()
        unsyncedIds.removeAll()
        fileMapping.removeAll()
        vectorStoreId = nil
        saveLocalData()
        host?.setUserDefault(nil, forKey: "vectorStoreId")
        await createVectorStoreIfNeeded()
    }

    // MARK: - Vector Store API

    private func createVectorStoreIfNeeded() async {
        guard let key = apiKey, vectorStoreId == nil else { return }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/vector_stores")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "TypeWhisper Memories"])
        request.timeoutInterval = 15

        guard let (data, response) = try? await PluginHTTPClient.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storeId = json["id"] as? String else { return }
        vectorStoreId = storeId
        host?.setUserDefault(storeId, forKey: "vectorStoreId")
    }

    private func flushUnsyncedEntries() async throws {
        guard let key = apiKey, let storeId = vectorStoreId, !unsyncedIds.isEmpty else { return }
        let entries = localEntries.filter { unsyncedIds.contains($0.id) }
        guard !entries.isEmpty else { return }
        try await uploadAndAttach(entries: entries, apiKey: key, storeId: storeId)
        unsyncedIds.removeAll()
        saveLocalData()
    }

    private func uploadAndAttach(entries: [MemoryEntry], apiKey: String, storeId: String) async throws {
        let content = entries.map { "[\($0.type.rawValue)] \($0.content)" }.joined(separator: "\n\n")
        let fileId = try await uploadFile(content: content, apiKey: apiKey)
        try await attachFileToStore(fileId: fileId, storeId: storeId, apiKey: apiKey)
        for entry in entries { fileMapping[entry.id] = fileId }
    }

    private func uploadFile(content: String, apiKey: String) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/files")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nassistants\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"memories-\(UUID().uuidString.prefix(8)).txt\"\r\nContent-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(content.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await PluginHTTPClient.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileId = json["id"] as? String else { throw PluginError.uploadFailed }
        return fileId
    }

    private func attachFileToStore(fileId: String, storeId: String, apiKey: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)/files")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileId])
        request.timeoutInterval = 15
        _ = try await PluginHTTPClient.data(for: request)
    }

    private func deleteFile(_ fileId: String) async throws {
        guard let key = apiKey else { return }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/files/\(fileId)")!)
        request.httpMethod = "DELETE"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        _ = try? await PluginHTTPClient.data(for: request)
    }

    private func deleteVectorStore(_ storeId: String) async throws {
        guard let key = apiKey else { return }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/vector_stores/\(storeId)")!)
        request.httpMethod = "DELETE"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = 10
        _ = try? await PluginHTTPClient.data(for: request)
    }

    // MARK: - Fallback Local Search

    private func fallbackLocalSearch(_ query: MemoryQuery) -> [MemorySearchResult] {
        let queryTokens = Set(query.text.lowercased().split(separator: " ").map(String.init))
        return Array(localEntries
            .filter { $0.confidence >= query.minConfidence }
            .compactMap { entry -> MemorySearchResult? in
                let content = entry.content.lowercased()
                guard queryTokens.contains(where: { content.contains($0) }) else { return nil }
                return MemorySearchResult(entry: entry, relevanceScore: 0.5 * entry.confidence)
            }
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(query.maxResults))
    }

    // MARK: - Local Persistence

    private func loadLocalData() {
        if let url = localEntriesURL, let data = try? Data(contentsOf: url) {
            localEntries = (try? JSONDecoder.memoryDecoder.decode([MemoryEntry].self, from: data)) ?? []
        }
        if let url = fileMappingURL, let data = try? Data(contentsOf: url) {
            let raw = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            fileMapping = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    private func saveLocalData() {
        if let url = localEntriesURL, let data = try? JSONEncoder.memoryEncoder.encode(localEntries) {
            try? data.write(to: url, options: .atomic)
        }
        if let url = fileMappingURL {
            let raw = Dictionary(uniqueKeysWithValues: fileMapping.map { ($0.key.uuidString, $0.value) })
            if let data = try? JSONEncoder().encode(raw) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Settings View Accessors

    fileprivate func setApiKey(_ key: String) {
        apiKey = key.isEmpty ? nil : key
        try? host?.storeSecret(key: "api-key", value: key)
        host?.notifyCapabilitiesChanged()
        if apiKey != nil && vectorStoreId == nil {
            Task { await createVectorStoreIfNeeded() }
        }
    }

    fileprivate func getApiKey() -> String { apiKey ?? "" }
    fileprivate func getStoreId() -> String? { vectorStoreId }
    fileprivate func getAllMemories() -> [MemoryEntry] { localEntries.sorted { $0.createdAt > $1.createdAt } }

    fileprivate func deleteMemory(_ id: UUID) {
        if let fileId = fileMapping.removeValue(forKey: id) {
            Task { try? await deleteFile(fileId) }
        }
        unsyncedIds.remove(id)
        localEntries.removeAll { $0.id == id }
        saveLocalData()
    }

    fileprivate func updateMemoryContent(_ id: UUID, newContent: String) {
        guard let index = localEntries.firstIndex(where: { $0.id == id }) else { return }
        localEntries[index].content = newContent
        localEntries[index].lastAccessedAt = Date()
        saveLocalData()
    }

    fileprivate func clearAllSync() {
        Task { try? await deleteAll() }
    }

    private enum PluginError: Error { case uploadFailed }
}

// MARK: - Settings View

private struct OpenAIVectorMemorySettingsView: View {
    let plugin: OpenAIVectorMemoryPlugin
    @State private var apiKey = ""
    @State private var memories: [MemoryEntry] = []
    @State private var isKeyVisible = false
    @State private var searchText = ""

    var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if isKeyVisible {
                    TextField("sk-...", text: $apiKey).textFieldStyle(.roundedBorder)
                } else {
                    SecureField("sk-...", text: $apiKey).textFieldStyle(.roundedBorder)
                }
                Button { isKeyVisible.toggle() } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                }.buttonStyle(.borderless)
                Button(String(localized: "Save")) { plugin.setApiKey(apiKey) }
            }

            HStack {
                Image(systemName: plugin.isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(plugin.isReady ? .green : .red).font(.caption)
                Text(plugin.isReady ? String(localized: "Connected") : String(localized: "Not configured")).font(.caption)
                if let storeId = plugin.getStoreId() {
                    Text("(\(storeId.prefix(12))...)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Label("\(memories.count)", systemImage: "brain.filled.head.profile").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { plugin.clearAllSync(); memories = [] } label: {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless).disabled(memories.isEmpty)
            }

            TextField(String(localized: "Search memories..."), text: $searchText).textFieldStyle(.roundedBorder)

            if filteredMemories.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Memories"), systemImage: "brain")
                } description: {
                    Text(searchText.isEmpty
                         ? String(localized: "Memories will appear here after transcriptions are processed.")
                         : String(localized: "No memories match your search."))
                }.frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(
                            memory: memory,
                            onDelete: { plugin.deleteMemory(memory.id); memories = plugin.getAllMemories() },
                            onSave: { plugin.updateMemoryContent(memory.id, newContent: $0); memories = plugin.getAllMemories() }
                        )
                    }
                }.listStyle(.inset)
            }
        }
        .padding()
        .frame(minHeight: 400)
        .onAppear { apiKey = plugin.getApiKey(); memories = plugin.getAllMemories() }
    }
}
