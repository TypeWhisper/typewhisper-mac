import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(LinearPlugin)
final class LinearPlugin: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.linear"
    static let pluginName = "Linear"

    var actionName: String { "Create Linear Issue" }
    var actionId: String { "linear-create-issue" }
    var actionIcon: String { "plus.rectangle.on.rectangle" }

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _defaultTeamId: String?
    fileprivate var _defaultProjectId: String?
    fileprivate var _defaultLabels: [String] = []

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _defaultTeamId = host.userDefault(forKey: "defaultTeamId") as? String
        _defaultProjectId = host.userDefault(forKey: "defaultProjectId") as? String
        _defaultLabels = host.userDefault(forKey: "defaultLabels") as? [String] ?? []
    }

    func deactivate() {
        host = nil
    }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    // MARK: - ActionPlugin

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            return ActionResult(success: false, message: "Linear API key not configured")
        }

        // Parse LLM output as JSON, fallback to plain text
        let (title, parsedDescription, priority) = parseInput(input)

        guard !title.isEmpty else {
            return ActionResult(success: false, message: "Could not extract issue title")
        }

        // Append source URL to description if available from browser context
        var description = parsedDescription
        if let sourceUrl = context.url, !sourceUrl.isEmpty {
            let label = context.appName ?? "Source"
            if description.isEmpty {
                description = "[\(label)](\(sourceUrl))"
            } else {
                description += "\n\n---\n[\(label)](\(sourceUrl))"
            }
        }

        // Build GraphQL mutation
        var inputFields = [String]()
        inputFields.append("title: \(escapeGraphQL(title))")
        inputFields.append("description: \(escapeGraphQL(description))")
        inputFields.append("priority: \(priority)")

        if let teamId = _defaultTeamId, !teamId.isEmpty {
            inputFields.append("teamId: \(escapeGraphQL(teamId))")
        } else {
            return ActionResult(success: false, message: "No default team configured")
        }

        if let projectId = _defaultProjectId, !projectId.isEmpty {
            inputFields.append("projectId: \(escapeGraphQL(projectId))")
        }

        if !_defaultLabels.isEmpty {
            let labelsArray = _defaultLabels.map { escapeGraphQL($0) }.joined(separator: ", ")
            inputFields.append("labelIds: [\(labelsArray)]")
        }

        let mutation = """
        mutation {
            issueCreate(input: { \(inputFields.joined(separator: ", ")) }) {
                success
                issue {
                    identifier
                    url
                    title
                }
            }
        }
        """

        let result = try await executeGraphQL(apiKey: apiKey, query: mutation)

        guard let issueCreate = result["issueCreate"] as? [String: Any],
              let success = issueCreate["success"] as? Bool, success,
              let issue = issueCreate["issue"] as? [String: Any],
              let identifier = issue["identifier"] as? String else {
            let errorMsg = (result["issueCreate"] as? [String: Any])?["success"] as? Bool == false
                ? "Linear API rejected the issue"
                : "Unexpected API response"
            return ActionResult(success: false, message: errorMsg)
        }

        let issueUrl = issue["url"] as? String
        return ActionResult(
            success: true,
            message: "\(identifier) created",
            url: issueUrl,
            icon: "checkmark.circle.fill",
            displayDuration: 4
        )
    }

    // MARK: - Input Parsing

    private func parseInput(_ input: String) -> (title: String, description: String, priority: Int) {
        // Try JSON parsing first
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = json["title"] as? String ?? ""
            let description = json["description"] as? String ?? ""
            let priority = json["priority"] as? Int ?? 3
            return (title, description, priority)
        }

        // Fallback: first line = title, rest = description
        let lines = input.components(separatedBy: .newlines)
        let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? input
        let description = lines.count > 1
            ? lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return (title, description, 3)
    }

    // MARK: - GraphQL

    private func executeGraphQL(apiKey: String, query: String) async throws -> [String: Any] {
        let url = URL(string: "https://api.linear.app/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LinearPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "LinearPlugin", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultData = json["data"] as? [String: Any] else {
            let errorMessage = extractGraphQLError(from: data)
            throw NSError(domain: "LinearPlugin", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Invalid API response"])
        }

        return resultData
    }

    private func extractGraphQLError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let firstError = errors.first,
              let message = firstError["message"] as? String else { return nil }
        return message
    }

    private func escapeGraphQL(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - Settings helpers

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[LinearPlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[LinearPlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func setDefaultTeam(_ teamId: String) {
        _defaultTeamId = teamId
        host?.setUserDefault(teamId, forKey: "defaultTeamId")
    }

    func setDefaultProject(_ projectId: String?) {
        _defaultProjectId = projectId
        host?.setUserDefault(projectId as Any, forKey: "defaultProjectId")
    }

    func setDefaultLabels(_ labelIds: [String]) {
        _defaultLabels = labelIds
        host?.setUserDefault(labelIds, forKey: "defaultLabels")
    }

    func fetchTeams() async throws -> [LinearTeam] {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return [] }
        let query = "{ teams { nodes { id name key } } }"
        let data = try await executeGraphQL(apiKey: apiKey, query: query)
        guard let teams = data["teams"] as? [String: Any],
              let nodes = teams["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let id = node["id"] as? String,
                  let name = node["name"] as? String,
                  let key = node["key"] as? String else { return nil }
            return LinearTeam(id: id, name: name, key: key)
        }
    }

    func fetchProjects(teamId: String) async throws -> [LinearProject] {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return [] }
        let query = """
        {
            team(id: \(escapeGraphQL(teamId))) {
                projects { nodes { id name } }
            }
        }
        """
        let data = try await executeGraphQL(apiKey: apiKey, query: query)
        guard let team = data["team"] as? [String: Any],
              let projects = team["projects"] as? [String: Any],
              let nodes = projects["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let id = node["id"] as? String,
                  let name = node["name"] as? String else { return nil }
            return LinearProject(id: id, name: name)
        }
    }

    func fetchLabels(teamId: String) async throws -> [LinearLabel] {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return [] }
        let query = """
        {
            team(id: \(escapeGraphQL(teamId))) {
                labels { nodes { id name color } }
            }
        }
        """
        let data = try await executeGraphQL(apiKey: apiKey, query: query)
        guard let team = data["team"] as? [String: Any],
              let labels = team["labels"] as? [String: Any],
              let nodes = labels["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node in
            guard let id = node["id"] as? String,
                  let name = node["name"] as? String else { return nil }
            let color = node["color"] as? String
            return LinearLabel(id: id, name: name, color: color)
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        let url = URL(string: "https://api.linear.app/graphql")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let body: [String: Any] = ["query": "{ viewer { id } }"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await PluginHTTPClient.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultData = json["data"] as? [String: Any],
              let viewer = resultData["viewer"] as? [String: Any],
              viewer["id"] != nil else {
            return false
        }
        return true
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(LinearSettingsView(plugin: self))
    }
}

// MARK: - Data Models

struct LinearTeam: Identifiable {
    let id: String
    let name: String
    let key: String
}

struct LinearProject: Identifiable {
    let id: String
    let name: String
}

struct LinearLabel: Identifiable {
    let id: String
    let name: String
    let color: String?
}

// MARK: - Settings View

private struct LinearSettingsView: View {
    let plugin: LinearPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false

    @State private var teams: [LinearTeam] = []
    @State private var selectedTeamId = ""
    @State private var projects: [LinearProject] = []
    @State private var selectedProjectId = ""
    @State private var labels: [LinearLabel] = []
    @State private var selectedLabelIds: Set<String> = []
    @State private var isLoadingTeams = false
    @State private var isLoadingDetails = false
    private let bundle = Bundle(for: LinearPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("lin_api_...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("lin_api_...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isConfigured {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            teams = []
                            projects = []
                            labels = []
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }

                Text("Create a personal API key at linear.app/settings/api", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if plugin.isConfigured {
                Divider()

                // Team & Project Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Defaults", bundle: bundle)
                        .font(.headline)

                    if isLoadingTeams {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Loading teams...", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !teams.isEmpty {
                        Picker(String(localized: "Team", bundle: bundle), selection: $selectedTeamId) {
                            Text("Select team...", bundle: bundle).tag("")
                            ForEach(teams) { team in
                                Text("\(team.key) - \(team.name)").tag(team.id)
                            }
                        }
                        .onChange(of: selectedTeamId) { _, newValue in
                            guard !newValue.isEmpty else { return }
                            plugin.setDefaultTeam(newValue)
                            loadTeamDetails(teamId: newValue)
                        }

                        if isLoadingDetails {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Loading projects & labels...", bundle: bundle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !projects.isEmpty {
                            Picker(String(localized: "Project", bundle: bundle), selection: $selectedProjectId) {
                                Text("None", bundle: bundle).tag("")
                                ForEach(projects) { project in
                                    Text(project.name).tag(project.id)
                                }
                            }
                            .onChange(of: selectedProjectId) { _, newValue in
                                plugin.setDefaultProject(newValue.isEmpty ? nil : newValue)
                            }
                        }

                        if !labels.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Labels", bundle: bundle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                FlowLayout(spacing: 4) {
                                    ForEach(labels) { label in
                                        let isSelected = selectedLabelIds.contains(label.id)
                                        Button {
                                            if isSelected {
                                                selectedLabelIds.remove(label.id)
                                            } else {
                                                selectedLabelIds.insert(label.id)
                                            }
                                            plugin.setDefaultLabels(Array(selectedLabelIds))
                                        } label: {
                                            HStack(spacing: 4) {
                                                if let color = label.color {
                                                    Circle()
                                                        .fill(Color(hex: color))
                                                        .frame(width: 8, height: 8)
                                                }
                                                Text(label.name)
                                                    .font(.caption)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                // Recommended prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended Prompt", bundle: bundle)
                        .font(.headline)

                    Text("Create a new PromptAction with this system prompt and set \"Create Linear Issue\" as the action target:", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let prompt = """
                    You are an assistant that converts spoken dictation into a structured Linear issue. Extract: 1) A concise title (max 100 chars), 2) A detailed description in markdown, 3) Priority (1=Urgent, 2=High, 3=Medium, 4=Low) - infer from context, default 3. Respond ONLY with valid JSON: {"title": "...", "description": "...", "priority": 3}
                    """
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)

                    Button(String(localized: "Copy Prompt", bundle: bundle)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedTeamId = plugin._defaultTeamId ?? ""
            selectedProjectId = plugin._defaultProjectId ?? ""
            selectedLabelIds = Set(plugin._defaultLabels)
            if plugin.isConfigured {
                loadTeams()
            }
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if isValid {
                    loadTeams()
                }
            }
        }
    }

    private func loadTeams() {
        isLoadingTeams = true
        Task {
            let fetchedTeams = (try? await plugin.fetchTeams()) ?? []
            await MainActor.run {
                teams = fetchedTeams
                isLoadingTeams = false
                if !selectedTeamId.isEmpty {
                    loadTeamDetails(teamId: selectedTeamId)
                }
            }
        }
    }

    private func loadTeamDetails(teamId: String) {
        isLoadingDetails = true
        Task {
            async let fetchedProjects = plugin.fetchProjects(teamId: teamId)
            async let fetchedLabels = plugin.fetchLabels(teamId: teamId)
            let (p, l) = try await (fetchedProjects, fetchedLabels)
            await MainActor.run {
                projects = p
                labels = l
                isLoadingDetails = false
            }
        }
    }
}

// MARK: - FlowLayout (for label chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

// MARK: - Color hex extension

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}
