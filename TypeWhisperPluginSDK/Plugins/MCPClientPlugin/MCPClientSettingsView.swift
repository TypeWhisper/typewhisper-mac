import AppKit
import SwiftUI

struct MCPClientSettingsView: View {
    let plugin: MCPClientPlugin
    private let bundle = Bundle(for: MCPClientPlugin.self)

    @State private var refreshToken = 0
    @State private var selectedTab = 0
    @State private var serverEditor: MCPServerConfiguration?
    @State private var actionEditor: MCPActionConfiguration?

    var body: some View {
        Group {
            if plugin.configurationLoadFailed {
                ContentUnavailableView(
                    String(localized: "MCP Configuration Unavailable", bundle: bundle),
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text(
                        "The stored MCP configuration could not be loaded. It was left unchanged to prevent data loss.",
                        bundle: bundle
                    )
                )
            } else {
                TabView(selection: $selectedTab) {
                    serversView
                        .tag(0)
                        .tabItem { Label(String(localized: "Servers", bundle: bundle), systemImage: "terminal") }
                    actionsView
                        .tag(1)
                        .tabItem { Label(String(localized: "Actions", bundle: bundle), systemImage: "bolt") }
                    activityView
                        .tag(2)
                        .tabItem { Label(String(localized: "Activity", bundle: bundle), systemImage: "clock") }
                }
                .id(refreshToken)
            }
        }
        .padding(16)
        .sheet(item: $serverEditor) { server in
            MCPServerEditorView(plugin: plugin, server: server) {
                serverEditor = nil
                refreshToken += 1
            }
        }
        .sheet(item: $actionEditor) { action in
            MCPActionEditorView(plugin: plugin, action: action) {
                actionEditor = nil
                refreshToken += 1
            }
        }
    }

    private var serversView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP Servers", bundle: bundle)
                        .font(.title2.weight(.semibold))
                    Text("Configure local MCP processes. Commands are launched directly, never through a shell.", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    serverEditor = MCPServerConfiguration(name: "", command: "")
                } label: {
                    Label(String(localized: "Add Server", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text("Add MCP server", bundle: bundle))
            }

            if plugin.servers.isEmpty {
                ContentUnavailableView(
                    String(localized: "No MCP Servers", bundle: bundle),
                    systemImage: "terminal",
                    description: Text("Add a stdio server to discover its tools.", bundle: bundle)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(plugin.servers) { server in
                    HStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.headline)
                            Text(([server.command] + server.arguments).joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(String(localized: "Edit", bundle: bundle)) {
                            serverEditor = server
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            plugin.removeServer(id: server.id)
                            refreshToken += 1
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove MCP server", bundle: bundle))
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private var actionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workflow Actions", bundle: bundle)
                        .font(.title2.weight(.semibold))
                    Text("Each saved action binds one workflow target to one MCP tool.", bundle: bundle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    actionEditor = newAction()
                } label: {
                    Label(String(localized: "Add Action", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(plugin.servers.isEmpty)
                .accessibilityLabel(Text("Add MCP action", bundle: bundle))
            }

            if plugin.actions.isEmpty {
                ContentUnavailableView(
                    String(localized: "No MCP Actions", bundle: bundle),
                    systemImage: "bolt",
                    description: Text(
                        plugin.servers.isEmpty
                            ? String(localized: "Add a server before creating an action.", bundle: bundle)
                            : String(localized: "Create an action and select it as a workflow Action Target.", bundle: bundle)
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(plugin.actions) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.symbolName)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.name).font(.headline)
                            Text("\(serverName(for: action.serverID)) · \(action.toolName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(
                            action.invocationMode == .single
                                ? String(localized: "Single", bundle: bundle)
                                : String(localized: "Batch", bundle: bundle)
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Edit", bundle: bundle)) {
                            actionEditor = action
                        }
                        .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            plugin.removeAction(id: action.id)
                            refreshToken += 1
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove MCP action", bundle: bundle))
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Text("Saving and selecting an action authorizes TypeWhisper to run that fixed tool automatically when the workflow completes.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity", bundle: bundle)
                .font(.title2.weight(.semibold))
            Text("Activity summaries never include transcripts, complete arguments, or secret values.", bundle: bundle)
                .foregroundStyle(.secondary)

            if plugin.activity.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Activity", bundle: bundle),
                    systemImage: "clock",
                    description: Text("Connection and action results appear here.", bundle: bundle)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(plugin.activity) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.status == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.status == .success ? .green : .orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.actionName ?? entry.serverName).font(.headline)
                            Text(entry.summary).textSelection(.enabled)
                            Text(entry.date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    private func serverName(for id: UUID) -> String {
        plugin.servers.first { $0.id == id }?.name ?? String(localized: "Missing server", bundle: bundle)
    }

    private func newAction() -> MCPActionConfiguration? {
        guard let server = plugin.servers.first else { return nil }
        let placeholderTool = MCPToolDescriptor(
            name: "",
            title: nil,
            description: nil,
            inputSchema: .object(["type": .string("object")]),
            destructiveHint: nil,
            readOnlyHint: nil
        )
        return MCPActionConfiguration(name: "", serverID: server.id, tool: placeholderTool)
    }
}

private struct MCPEditableArgument: Identifiable {
    let id = UUID()
    var value: String
}

private struct MCPEditableEnvironment: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    var isSecret: Bool
}

private struct MCPServerEditorView: View {
    let plugin: MCPClientPlugin
    let original: MCPServerConfiguration
    let onDone: () -> Void
    private let bundle = Bundle(for: MCPClientPlugin.self)

    @State private var name: String
    @State private var command: String
    @State private var arguments: [MCPEditableArgument]
    @State private var environment: [MCPEditableEnvironment]
    @State private var launchAcknowledged: Bool
    @State private var resolvedPath = ""
    @State private var tools: [MCPToolDescriptor] = []
    @State private var isConnecting = false
    @State private var errorMessage: String?

    init(plugin: MCPClientPlugin, server: MCPServerConfiguration, onDone: @escaping () -> Void) {
        self.plugin = plugin
        original = server
        self.onDone = onDone
        _name = State(initialValue: server.name)
        _command = State(initialValue: server.command)
        _arguments = State(initialValue: server.arguments.map { MCPEditableArgument(value: $0) })
        let plainRows = server.environment.keys.sorted().map {
            MCPEditableEnvironment(name: $0, value: server.environment[$0] ?? "", isSecret: false)
        }
        let secretRows = server.secretEnvironmentNames.sorted().map {
            MCPEditableEnvironment(name: $0, value: plugin.secretValue(serverID: server.id, name: $0), isSecret: true)
        }
        _environment = State(initialValue: plainRows + secretRows)
        _launchAcknowledged = State(initialValue: server.launchAcknowledged)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    original.name.isEmpty
                        ? String(localized: "Add MCP Server", bundle: bundle)
                        : String(localized: "Edit MCP Server", bundle: bundle)
                )
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(String(localized: "Cancel", bundle: bundle), action: onDone)
                Button(String(localized: "Save", bundle: bundle), action: save)
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            Form {
                Section(String(localized: "Server", bundle: bundle)) {
                    TextField(String(localized: "Name", bundle: bundle), text: $name)
                    TextField(String(localized: "Command", bundle: bundle), text: $command)
                        .font(.system(.body, design: .monospaced))
                    if !resolvedPath.isEmpty {
                        LabeledContent(String(localized: "Resolved executable", bundle: bundle)) {
                            Text(resolvedPath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Section(String(localized: "Arguments", bundle: bundle)) {
                    ForEach($arguments) { $argument in
                        HStack {
                            TextField(String(localized: "Argument", bundle: bundle), text: $argument.value)
                                .font(.system(.body, design: .monospaced))
                            Button {
                                moveArgument(id: argument.id, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(arguments.first?.id == argument.id)
                            .accessibilityLabel(Text("Move argument up", bundle: bundle))
                            Button {
                                moveArgument(id: argument.id, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(arguments.last?.id == argument.id)
                            .accessibilityLabel(Text("Move argument down", bundle: bundle))
                            Button(role: .destructive) {
                                arguments.removeAll { $0.id == argument.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove argument", bundle: bundle))
                        }
                    }
                    Button {
                        arguments.append(MCPEditableArgument(value: ""))
                    } label: {
                        Label(String(localized: "Add Argument", bundle: bundle), systemImage: "plus")
                    }
                    .accessibilityLabel(Text("Add argument", bundle: bundle))
                }

                Section(String(localized: "Environment", bundle: bundle)) {
                    ForEach($environment) { $variable in
                        HStack {
                            TextField("NAME", text: $variable.name)
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 120)
                            if variable.isSecret {
                                SecureField(String(localized: "Value", bundle: bundle), text: $variable.value)
                            } else {
                                TextField(String(localized: "Value", bundle: bundle), text: $variable.value)
                            }
                            Toggle(String(localized: "Secret", bundle: bundle), isOn: $variable.isSecret)
                                .toggleStyle(.checkbox)
                                .accessibilityLabel(Text("Store environment value in Keychain", bundle: bundle))
                            Button(role: .destructive) {
                                environment.removeAll { $0.id == variable.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Remove environment value", bundle: bundle))
                        }
                    }
                    Button {
                        environment.append(MCPEditableEnvironment(name: "", value: "", isSecret: false))
                    } label: {
                        Label(String(localized: "Add Environment Value", bundle: bundle), systemImage: "plus")
                    }
                }

                Section(String(localized: "Authorization", bundle: bundle)) {
                    Toggle(isOn: $launchAcknowledged) {
                        Text(
                            String(
                                format: String(
                                    localized: "I understand that TypeWhisper will launch %@ with my user permissions.",
                                    bundle: bundle
                                ),
                                resolvedPath.isEmpty ? command : resolvedPath
                            )
                        )
                    }
                    .toggleStyle(.checkbox)

                    Text("The command is not interpreted by a shell. The process may still access files and services available to your macOS user.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Connection", bundle: bundle)) {
                    Button(action: connectAndLoadTools) {
                        if isConnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(String(localized: "Connect & Load Tools", bundle: bundle), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isConnecting)

                    if !tools.isEmpty {
                        Text(
                            String(
                                format: String(localized: "Loaded %lld tools", bundle: bundle),
                                Int64(tools.count)
                            )
                        )
                            .foregroundStyle(.green)
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title ?? tool.name).font(.headline)
                                Text(tool.name).font(.system(.caption, design: .monospaced))
                                if let description = tool.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear(perform: updateResolvedPath)
        .onChange(of: command) { _, _ in updateResolvedPath() }
        .onChange(of: environment.map { "\($0.name)=\($0.value)" }) { _, _ in updateResolvedPath() }
    }

    private func makeDraft() throws -> (MCPServerConfiguration, [String: String]) {
        let rows = environment.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let names = rows.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(names).count == names.count else {
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string("Environment variable names must be unique.")
            )
        }
        var plain: [String: String] = [:]
        var secrets: [String: String] = [:]
        for row in rows {
            let key = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.isSecret {
                secrets[key] = row.value
            } else {
                plain[key] = row.value
            }
        }

        let draft = MCPServerConfiguration(
            id: original.id,
            name: name,
            command: command,
            arguments: arguments.map(\.value).filter { !$0.isEmpty },
            environment: plain,
            secretEnvironmentNames: secrets.keys.sorted(),
            launchAcknowledged: launchAcknowledged,
            revision: original.revision,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        return (draft, secrets)
    }

    private func save() {
        do {
            let (draft, secrets) = try makeDraft()
            try plugin.saveServer(draft, secretValues: secrets)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectAndLoadTools() {
        do {
            let (draft, secrets) = try makeDraft()
            isConnecting = true
            errorMessage = nil
            Task {
                do {
                    let loaded = try await plugin.discoverTools(server: draft, secretValues: secrets)
                    await MainActor.run {
                        tools = loaded
                        isConnecting = false
                        updateResolvedPath()
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        isConnecting = false
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateResolvedPath() {
        do {
            let (draft, secrets) = try makeDraft()
            resolvedPath = try plugin.resolvedExecutable(for: draft, secretValues: secrets).path
        } catch {
            resolvedPath = ""
        }
    }

    private func moveArgument(id: UUID, offset: Int) {
        guard let source = arguments.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard arguments.indices.contains(destination) else { return }
        arguments.swapAt(source, destination)
    }
}

private struct MCPBindingDraft: Identifiable {
    var id: String { property.name }
    let property: MCPToolProperty
    var isEnabled: Bool
    var source: MCPBindingSource
    var detail: String
}

private struct MCPActionEditorView: View {
    let plugin: MCPClientPlugin
    let original: MCPActionConfiguration
    let onDone: () -> Void
    private let bundle = Bundle(for: MCPClientPlugin.self)

    @State private var name: String
    @State private var symbolName: String
    @State private var serverID: UUID
    @State private var tools: [MCPToolDescriptor] = []
    @State private var selectedToolName: String
    @State private var invocationMode: MCPInvocationMode
    @State private var bindings: [MCPBindingDraft] = []
    @State private var usesRawJSONArguments: Bool
    @State private var rawArgumentsSource: MCPRawArgumentsSource
    @State private var rawLiteralJSON: String
    @State private var destructiveAcknowledged: Bool
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toolLoadRequestID = UUID()
    @State private var toolLoadFailed = false

    init(plugin: MCPClientPlugin, action: MCPActionConfiguration, onDone: @escaping () -> Void) {
        self.plugin = plugin
        original = action
        self.onDone = onDone
        _name = State(initialValue: action.name)
        _symbolName = State(initialValue: action.symbolName)
        _serverID = State(initialValue: action.serverID)
        _selectedToolName = State(initialValue: action.toolName)
        _invocationMode = State(initialValue: action.invocationMode)
        _usesRawJSONArguments = State(initialValue: action.usesRawJSONArguments)
        _rawArgumentsSource = State(initialValue: action.rawArgumentsSource)
        _rawLiteralJSON = State(initialValue: action.rawLiteralJSON)
        _destructiveAcknowledged = State(initialValue: action.destructiveAcknowledged)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    original.name.isEmpty
                        ? String(localized: "Add MCP Action", bundle: bundle)
                        : String(localized: "Edit MCP Action", bundle: bundle)
                )
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(String(localized: "Cancel", bundle: bundle), action: onDone)
                Button(String(localized: "Save", bundle: bundle), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTool == nil)
            }
            .padding()

            Divider()

            Form {
                Section(String(localized: "Action", bundle: bundle)) {
                    TextField(String(localized: "Name", bundle: bundle), text: $name)
                    TextField(String(localized: "SF Symbol", bundle: bundle), text: $symbolName)
                    Picker(String(localized: "Server", bundle: bundle), selection: $serverID) {
                        ForEach(plugin.servers) { server in
                            Text(server.name).tag(server.id)
                        }
                    }
                    .onChange(of: serverID) { _, _ in loadTools(resetSelection: true) }
                    Picker(String(localized: "Mode", bundle: bundle), selection: $invocationMode) {
                        Text("Single", bundle: bundle).tag(MCPInvocationMode.single)
                        Text("Batch", bundle: bundle).tag(MCPInvocationMode.batch)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: invocationMode) { _, mode in
                        if mode == .single, rawArgumentsSource == .currentBatchItem {
                            rawArgumentsSource = .processedText
                        } else if mode == .batch, usesRawJSONArguments {
                            rawArgumentsSource = .currentBatchItem
                        }
                        configureBindings(for: selectedTool)
                    }
                }

                Section(String(localized: "Tool", bundle: bundle)) {
                    if isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading tools…", bundle: bundle)
                        }
                    } else {
                        Picker(String(localized: "MCP Tool", bundle: bundle), selection: $selectedToolName) {
                            Text("Select a tool…", bundle: bundle).tag("")
                            ForEach(displayedTools) { tool in
                                Text(tool.title ?? tool.name).tag(tool.name)
                            }
                        }
                        .onChange(of: selectedToolName) { _, _ in
                            destructiveAcknowledged = false
                            configureBindings(for: selectedTool)
                        }
                        Button(String(localized: "Refresh Tools", bundle: bundle)) {
                            loadTools(resetSelection: false)
                        }
                    }

                    if let tool = selectedTool {
                        if let description = tool.description {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(tool.inputSchema.canonicalJSONString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(8)
                    }
                }

                if selectedTool != nil {
                    Section(String(localized: "Arguments", bundle: bundle)) {
                        Toggle(String(localized: "Raw JSON Arguments", bundle: bundle), isOn: $usesRawJSONArguments)
                            .toggleStyle(.checkbox)
                            .onChange(of: usesRawJSONArguments) { _, usesRaw in
                                if usesRaw, invocationMode == .batch {
                                    rawArgumentsSource = .currentBatchItem
                                }
                            }

                        if usesRawJSONArguments {
                            Picker(String(localized: "JSON Source", bundle: bundle), selection: $rawArgumentsSource) {
                                if invocationMode == .batch {
                                    Text("Current batch item", bundle: bundle).tag(MCPRawArgumentsSource.currentBatchItem)
                                } else {
                                    Text("Processed workflow JSON", bundle: bundle).tag(MCPRawArgumentsSource.processedText)
                                    Text("Literal JSON", bundle: bundle).tag(MCPRawArgumentsSource.literalJSON)
                                }
                            }
                            if rawArgumentsSource == .literalJSON {
                                TextEditor(text: $rawLiteralJSON)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minHeight: 100)
                                    .border(Color.secondary.opacity(0.3))
                            }
                        } else if bindings.isEmpty {
                            Text("This tool has no top-level properties to map. Use Raw JSON Arguments for complex schemas.", bundle: bundle)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($bindings) { $binding in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Toggle(isOn: $binding.isEnabled) {
                                            Text(binding.property.name)
                                                .font(.system(.body, design: .monospaced))
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(binding.property.isRequired)
                                        if binding.property.isRequired {
                                            Text("Required", bundle: bundle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(binding.property.type?.rawValue ?? "any")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if binding.isEnabled {
                                        Picker(String(localized: "Source", bundle: bundle), selection: $binding.source) {
                                            ForEach(allowedSources(for: binding.property), id: \.self) { source in
                                                Text(localizedName(for: source)).tag(source)
                                            }
                                        }
                                        if binding.source == .jsonProperty {
                                            TextField(String(localized: "Property path", bundle: bundle), text: $binding.detail)
                                                .font(.system(.body, design: .monospaced))
                                        } else if binding.source == .literal {
                                            TextField(String(localized: "Literal JSON value", bundle: bundle), text: $binding.detail)
                                                .font(.system(.body, design: .monospaced))
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section(String(localized: "Automatic Execution", bundle: bundle)) {
                        Text("This fixed MCP tool runs automatically whenever a workflow using this Action Target completes.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if selectedTool?.destructiveHint == true {
                            Toggle(isOn: $destructiveAcknowledged) {
                                Text("I understand that this tool is marked destructive and may change or delete external data.", bundle: bundle)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                    Section(String(localized: "Argument Preview", bundle: bundle)) {
                        Text(argumentPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if invocationMode == .batch {
                    Section {
                        Text("Batch mode expects a JSON array, validates all items before the first call, runs at most 100 items sequentially, and never retries writes automatically.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 700, minHeight: 600)
        .onAppear { loadTools(resetSelection: false) }
    }

    private var selectedTool: MCPToolDescriptor? {
        displayedTools.first { $0.name == selectedToolName }
    }

    private var displayedTools: [MCPToolDescriptor] {
        guard toolLoadFailed,
              serverID == original.serverID,
              !original.toolName.isEmpty,
              !tools.contains(where: { $0.name == original.toolName }) else {
            return tools
        }
        return tools + [persistedTool]
    }

    private var persistedTool: MCPToolDescriptor {
        MCPToolDescriptor(
            name: original.toolName,
            title: nil,
            description: nil,
            inputSchema: original.toolInputSchema,
            destructiveHint: original.toolDestructiveHint,
            readOnlyHint: nil
        )
    }

    private func loadTools(resetSelection: Bool) {
        let requestID = UUID()
        let requestedServerID = serverID
        toolLoadRequestID = requestID
        toolLoadFailed = false
        if resetSelection {
            selectedToolName = ""
            bindings = []
            tools = []
        }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let loaded = try await plugin.discoverTools(serverID: requestedServerID)
                await MainActor.run {
                    guard toolLoadRequestID == requestID else { return }
                    tools = loaded
                    toolLoadFailed = false
                    isLoading = false
                    configureBindings(for: selectedTool)
                }
            } catch {
                await MainActor.run {
                    guard toolLoadRequestID == requestID else { return }
                    errorMessage = error.localizedDescription
                    toolLoadFailed = true
                    isLoading = false
                }
            }
        }
    }

    private func configureBindings(for tool: MCPToolDescriptor?) {
        guard let tool else {
            bindings = []
            return
        }

        let compatibleBindings = MCPClientPlugin.compatibleBindings(from: original, for: tool)
        let savedBindings = Dictionary(uniqueKeysWithValues: compatibleBindings.map { ($0.targetProperty, $0) })
        let automatic = MCPClientPlugin.defaultBindings(for: tool, mode: invocationMode).first
        bindings = tool.topLevelProperties.map { property in
            if tool.name == original.toolName, let saved = savedBindings[property.name] {
                return MCPBindingDraft(
                    property: property,
                    isEnabled: true,
                    source: saved.source,
                    detail: saved.propertyPath ?? saved.literalValue?.canonicalJSONString ?? ""
                )
            }
            if automatic?.targetProperty == property.name {
                return MCPBindingDraft(
                    property: property,
                    isEnabled: true,
                    source: automatic?.source ?? .processedText,
                    detail: ""
                )
            }
            return MCPBindingDraft(
                property: property,
                isEnabled: property.isRequired,
                source: .literal,
                detail: property.type == .string ? "" : "null"
            )
        }
    }

    private func allowedSources(for property: MCPToolProperty) -> [MCPBindingSource] {
        var sources: [MCPBindingSource] = [
            .processedText,
            .originalTranscript,
            .jsonProperty,
            .activeApplicationName,
            .activeApplicationBundleIdentifier,
            .activeApplicationURL,
            .detectedLanguage,
            .literal,
        ]
        if invocationMode == .batch {
            sources.insert(.currentBatchItem, at: 1)
        }
        if property.type != nil && property.type != .string {
            sources.removeAll {
                [.processedText, .originalTranscript, .activeApplicationName,
                 .activeApplicationBundleIdentifier, .activeApplicationURL, .detectedLanguage].contains($0)
            }
        }
        return sources
    }

    private func localizedName(for source: MCPBindingSource) -> String {
        switch source {
        case .processedText:
            String(localized: "Processed workflow text", bundle: bundle)
        case .originalTranscript:
            String(localized: "Original transcript", bundle: bundle)
        case .currentBatchItem:
            String(localized: "Current batch item", bundle: bundle)
        case .jsonProperty:
            String(localized: "JSON property path", bundle: bundle)
        case .activeApplicationName:
            String(localized: "Active application name", bundle: bundle)
        case .activeApplicationBundleIdentifier:
            String(localized: "Active application bundle identifier", bundle: bundle)
        case .activeApplicationURL:
            String(localized: "Active application URL", bundle: bundle)
        case .detectedLanguage:
            String(localized: "Detected language", bundle: bundle)
        case .literal:
            String(localized: "Literal value", bundle: bundle)
        }
    }

    private var argumentPreview: String {
        guard let tool = selectedTool else { return "{}" }
        if usesRawJSONArguments {
            if rawArgumentsSource == .literalJSON,
               let value = try? MCPJSONValue.parse(rawLiteralJSON),
               value.objectValue != nil {
                return value.canonicalJSONString
            }
            return String(localized: "Arguments come from runtime JSON.", bundle: bundle)
        }

        let action = MCPActionConfiguration(
            id: original.id,
            name: name,
            symbolName: symbolName,
            serverID: serverID,
            tool: tool,
            bindings: bindings.filter(\.isEnabled).map { draft in
                MCPArgumentBinding(
                    targetProperty: draft.property.name,
                    expectedType: draft.property.type,
                    source: draft.source,
                    propertyPath: draft.source == .jsonProperty ? draft.detail : nil,
                    literalValue: draft.source == .literal ? previewLiteral(for: draft) : nil
                )
            },
            invocationMode: invocationMode
        )
        return MCPJSONValue.object(MCPArgumentPreview.arguments(for: action)).canonicalJSONString
    }

    private func previewLiteral(for draft: MCPBindingDraft) -> MCPJSONValue? {
        if draft.property.type == .string {
            return .string(draft.detail)
        }
        return try? MCPJSONValue.parse(draft.detail)
    }

    private func save() {
        guard let tool = selectedTool else { return }
        do {
            let mappedBindings = try bindings.filter(\.isEnabled).map { draft -> MCPArgumentBinding in
                let literal: MCPJSONValue?
                if draft.source == .literal {
                    if draft.property.type == .string {
                        literal = .string(draft.detail)
                    } else {
                        literal = try MCPJSONValue.parse(draft.detail)
                    }
                } else {
                    literal = nil
                }
                return MCPArgumentBinding(
                    targetProperty: draft.property.name,
                    expectedType: draft.property.type,
                    source: draft.source,
                    propertyPath: draft.source == .jsonProperty ? draft.detail : nil,
                    literalValue: literal
                )
            }

            var action = MCPActionConfiguration(
                id: original.id,
                name: name,
                symbolName: symbolName.isEmpty ? "point.3.connected.trianglepath.dotted" : symbolName,
                serverID: serverID,
                tool: tool,
                bindings: mappedBindings,
                invocationMode: invocationMode,
                usesRawJSONArguments: usesRawJSONArguments,
                rawArgumentsSource: rawArgumentsSource,
                rawLiteralJSON: rawLiteralJSON,
                destructiveAcknowledged: destructiveAcknowledged,
                createdAt: original.createdAt,
                updatedAt: original.updatedAt
            )
            action.schemaFingerprint = tool.schemaFingerprint
            try plugin.saveAction(action)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
