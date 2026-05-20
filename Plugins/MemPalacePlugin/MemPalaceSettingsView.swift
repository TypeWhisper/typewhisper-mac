import Foundation
import SwiftUI
import TypeWhisperPluginSDK

struct MemPalaceSettingsView: View {
    let plugin: MemPalacePlugin

    @State private var deployment: MemPalaceDeployment = .cloud
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var wing: String = "wing_typewhisper"
    @State private var room: String = "captures"
    @State private var availableWings: [String] = []
    @State private var availableRooms: [String] = []
    @State private var memories: [MemoryEntry] = []
    @State private var searchText: String = ""
    @State private var statusMessage: String = ""
    @State private var statusIsError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionSection
            wingRoomSection
            statusSection
            Divider()
            memoryBrowserSection
        }
        .padding()
        .onAppear { Task { await loadFromPlugin() } }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Connection")).font(.headline)

            Picker(String(localized: "Deployment"), selection: $deployment) {
                ForEach(MemPalaceDeployment.allCases) { d in
                    Text(d.displayName).tag(d)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: deployment) { _, newValue in
                if newValue == .cloud {
                    baseURL = MemPalaceDeployment.cloud.defaultBaseURL
                }
            }

            HStack {
                Text(String(localized: "Base URL"))
                    .frame(width: 90, alignment: .leading)
                TextField("https://api.mempalace.cloud", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(deployment == .cloud)
            }

            HStack {
                Text(String(localized: "API Key"))
                    .frame(width: 90, alignment: .leading)
                SecureField(String(localized: "Paste API key"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button(String(localized: "Save & Test")) { Task { await saveAndTest() } }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    private var wingRoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Filing Location")).font(.headline)

            HStack {
                Text(String(localized: "Wing")).frame(width: 60, alignment: .leading)
                TextField("wing_typewhisper", text: $wing)
                    .textFieldStyle(.roundedBorder)
                Menu(String(localized: "Pick")) {
                    ForEach(availableWings, id: \.self) { w in
                        Button(w) { wing = w; Task { await loadRooms(for: w) } }
                    }
                }.disabled(availableWings.isEmpty)
            }

            HStack {
                Text(String(localized: "Room")).frame(width: 60, alignment: .leading)
                TextField("captures", text: $room)
                    .textFieldStyle(.roundedBorder)
                Menu(String(localized: "Pick")) {
                    ForEach(availableRooms, id: \.self) { r in
                        Button(r) { room = r }
                    }
                }.disabled(availableRooms.isEmpty)
            }

            HStack {
                Button(String(localized: "Refresh Wings/Rooms")) { Task { await refreshTaxonomy() } }
                Button(String(localized: "Apply Filing")) { applyConfig() }
            }
        }
    }

    private var statusSection: some View {
        Group {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
            }
        }
    }

    private var memoryBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(memories.count) " + String(localized: "memories"), systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) { Task { await clearAll() } } label: {
                    Label(String(localized: "Clear All"), systemImage: "trash")
                }.disabled(memories.isEmpty)
            }

            TextField(String(localized: "Filter memories..."), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredMemories.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Memories"), systemImage: "brain")
                } description: {
                    Text(searchText.isEmpty
                         ? String(localized: "Stored memories appear here after transcriptions.")
                         : String(localized: "No memories match your filter."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(
                            memory: memory,
                            onDelete: { Task { await deleteEntry(memory.id) } },
                            onSave: { newContent in Task { await updateEntry(memory, newContent: newContent) } }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: - Actions

    private func loadFromPlugin() async {
        let cfg = plugin.currentConfig()
        deployment = cfg.deployment
        baseURL = cfg.baseURL
        wing = cfg.wing
        room = cfg.room
        apiKey = plugin.currentAPIKey() ?? ""
        memories = await plugin.listAllSidecarEntries()
    }

    private func candidateConfig() -> MemPalaceConfig {
        var cfg = plugin.currentConfig()
        cfg.deployment = deployment
        cfg.baseURL = baseURL
        cfg.wing = wing.trimmingCharacters(in: .whitespaces)
        cfg.room = room.trimmingCharacters(in: .whitespaces)
        return cfg
    }

    private func applyConfig() {
        let cfg = candidateConfig()
        guard cfg.isValid else {
            statusMessage = String(localized: "Wing, Room, and base URL must be set.")
            statusIsError = true
            return
        }
        _ = plugin.updateConfig(cfg)
        statusMessage = String(localized: "Filing saved.")
        statusIsError = false
    }

    private func saveAndTest() async {
        plugin.updateAPIKey(apiKey)
        let cfg = candidateConfig()
        guard cfg.isValid else {
            statusMessage = String(localized: "Wing, Room, and base URL must be set.")
            statusIsError = true
            return
        }
        guard plugin.updateConfig(cfg) else {
            statusMessage = String(localized: "Could not apply configuration.")
            statusIsError = true
            return
        }
        await refreshTaxonomy(silent: false)
    }

    private func refreshTaxonomy(silent: Bool = true) async {
        guard plugin.isReady else {
            if !silent {
                statusMessage = String(localized: "Configure API key, URL, wing, and room first.")
                statusIsError = true
            }
            return
        }
        do {
            availableWings = try await fetchWings()
            availableRooms = try await fetchRooms(wing: wing)
            statusMessage = String(localized: "Connection OK")
            statusIsError = false
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func loadRooms(for wing: String) async {
        availableRooms = (try? await fetchRooms(wing: wing)) ?? []
    }

    private func fetchWings() async throws -> [String] {
        try await plugin.taxonomyClient()?.listWings() ?? []
    }

    private func fetchRooms(wing: String) async throws -> [String] {
        try await plugin.taxonomyClient()?.listRooms(wing: wing) ?? []
    }

    private func deleteEntry(_ id: UUID) async {
        try? await plugin.delete([id])
        memories = await plugin.listAllSidecarEntries()
    }

    private func updateEntry(_ entry: MemoryEntry, newContent: String) async {
        var updated = entry
        updated.content = newContent
        try? await plugin.update(updated)
        memories = await plugin.listAllSidecarEntries()
    }

    private func clearAll() async {
        try? await plugin.deleteAll()
        memories = []
    }
}
