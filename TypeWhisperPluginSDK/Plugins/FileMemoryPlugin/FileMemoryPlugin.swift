import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(FileMemoryPlugin)
final class FileMemoryPlugin: NSObject, TypeWhisperPlugin, MemoryStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.memory.file"
    static let pluginName = "File Memory"

    var storageName: String { "File Memory" }
    var isReady: Bool { host != nil }
    var memoryCount: Int { memories.count }

    private var host: HostServices?
    private var memories: [MemoryEntry] = []
    private var memoriesFileURL: URL?
    private var isDirty = false
    private var saveTask: Task<Void, Never>?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        memoriesFileURL = host.pluginDataDirectory.appendingPathComponent("memories.json")
        loadMemories()
    }

    func deactivate() {
        saveTask?.cancel()
        if isDirty { persistNow() }
        host = nil
        memories = []
        memoriesFileURL = nil
    }

    var settingsView: AnyView? {
        AnyView(FileMemorySettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    func store(_ entries: [MemoryEntry]) async throws {
        memories.append(contentsOf: entries)
        scheduleSave()
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        let queryTokens = tokenize(query.text)
        guard !queryTokens.isEmpty else { return [] }

        let now = Date()
        var results: [MemorySearchResult] = []

        for memory in memories {
            guard memory.confidence >= query.minConfidence else { continue }
            if let types = query.types, !types.contains(memory.type) { continue }

            let memoryTokens = tokenize(memory.content)
            guard !memoryTokens.isEmpty else { continue }

            let matchCount = queryTokens.filter { qt in
                memoryTokens.contains { $0.contains(qt) || qt.contains($0) }
            }.count
            guard matchCount > 0 else { continue }

            let overlap = Double(matchCount) / Double(queryTokens.count)
            let daysSinceAccess = now.timeIntervalSince(memory.lastAccessedAt) / 86400
            let recencyBoost = 1.0 / (1.0 + daysSinceAccess * 0.01)

            results.append(MemorySearchResult(entry: memory, relevanceScore: overlap * memory.confidence * recencyBoost))
        }

        return Array(results.sorted { $0.relevanceScore > $1.relevanceScore }.prefix(query.maxResults))
    }

    func delete(_ ids: [UUID]) async throws {
        memories.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func update(_ entry: MemoryEntry) async throws {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        memories[index] = entry
        scheduleSave()
    }

    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        let sorted = memories.sorted { $0.createdAt > $1.createdAt }
        let start = min(offset, sorted.count)
        return Array(sorted[start..<min(start + limit, sorted.count)])
    }

    func deleteAll() async throws {
        memories.removeAll()
        persistNow()
    }

    // MARK: - Persistence (coalesced)

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard isDirty, let url = memoriesFileURL else { return }
        isDirty = false
        guard let data = try? JSONEncoder.memoryEncoder.encode(memories) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadMemories() {
        guard let url = memoriesFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        memories = (try? JSONDecoder.memoryDecoder.decode([MemoryEntry].self, from: data)) ?? []
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    // MARK: - Settings View Accessors

    func getAllMemories() -> [MemoryEntry] {
        memories.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        scheduleSave()
    }

    func updateMemoryContent(_ id: UUID, newContent: String) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].content = newContent
        memories[index].lastAccessedAt = Date()
        scheduleSave()
    }

    func clearAll() {
        memories.removeAll()
        persistNow()
    }
}

// MARK: - Settings View

private struct FileMemorySettingsView: View {
    let plugin: FileMemoryPlugin
    @State private var memories: [MemoryEntry] = []
    @State private var searchText = ""

    var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(memories.count) memories stored", systemImage: "brain.filled.head.profile")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    plugin.clearAll()
                    memories = []
                } label: {
                    Label(String(localized: "Clear All"), systemImage: "trash")
                }
                .disabled(memories.isEmpty)
            }

            TextField(String(localized: "Search memories..."), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredMemories.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Memories"), systemImage: "brain")
                } description: {
                    Text(searchText.isEmpty
                         ? String(localized: "Memories will appear here after transcriptions are processed.")
                         : String(localized: "No memories match your search."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(
                            memory: memory,
                            onDelete: {
                                plugin.deleteMemory(memory.id)
                                memories = plugin.getAllMemories()
                            },
                            onSave: { newContent in
                                plugin.updateMemoryContent(memory.id, newContent: newContent)
                                memories = plugin.getAllMemories()
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .onAppear { memories = plugin.getAllMemories() }
    }
}
