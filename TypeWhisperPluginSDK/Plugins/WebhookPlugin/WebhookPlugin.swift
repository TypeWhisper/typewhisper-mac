// Example TypeWhisper Plugin - Webhook Notifications
//
// This is a reference implementation showing how to build an external
// TypeWhisper plugin as a .bundle. The builtin webhook integration in
// TypeWhisper uses the same SDK patterns shown here.
//
// To build your own plugin:
// 1. Create a new macOS Bundle target
// 2. Add TypeWhisperPluginSDK as a dependency
// 3. Implement the TypeWhisperPlugin protocol
// 4. Create a manifest.json in Contents/Resources/
// 5. Place the built .bundle in ~/Library/Application Support/TypeWhisper/Plugins/

import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(WebhookPlugin)
final class WebhookPlugin: NSObject, TypeWhisperPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.webhook"
    static let pluginName = "Webhook Notifications"

    private var host: HostServices?
    private var subscriptionId: UUID?
    private var service: ExampleWebhookService?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host

        // Create the service with the plugin's data directory for persistence
        let svc = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        self.service = svc

        // Subscribe to transcription events via the Event Bus
        subscriptionId = host.eventBus.subscribe { [weak svc] event in
            switch event {
            case .transcriptionCompleted(let payload):
                await svc?.sendWebhooks(for: payload)
            default:
                break
            }
        }
    }

    func deactivate() {
        // Unsubscribe from events and clean up
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }
        host = nil
        service = nil
    }

    // Provide a settings view for the Plugin Settings UI
    var settingsView: AnyView? {
        guard let service else { return nil }
        return AnyView(ExampleWebhookSettingsView(service: service))
    }
}

// MARK: - Webhook Config Model

struct ExampleWebhookConfig: Codable, Identifiable {
    static let secretHeaderPlaceholder = "__typewhisper_keychain_secret__"

    var id: UUID
    var name: String
    var url: String
    var httpMethod: String
    var headers: [String: String]
    var secretHeaderNames: [String]
    var isEnabled: Bool
    var workflowFilter: [String]  // Empty = all transcriptions

    init(name: String = "", url: String = "", httpMethod: String = "POST",
         headers: [String: String] = ["Content-Type": "application/json"],
         secretHeaderNames: [String] = [],
         isEnabled: Bool = true, workflowFilter: [String] = []) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.httpMethod = httpMethod
        self.headers = headers
        self.secretHeaderNames = secretHeaderNames
        self.isEnabled = isEnabled
        self.workflowFilter = workflowFilter
    }

    var isUnmodifiedDefaultDraft: Bool {
        name.isEmpty
            && url.isEmpty
            && httpMethod == "POST"
            && headers == ["Content-Type": "application/json"]
            && secretHeaderNames.isEmpty
            && isEnabled
            && workflowFilter.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case httpMethod
        case headers
        case secretHeaderNames
        case isEnabled
        case workflowFilter = "profileFilter"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        httpMethod = try container.decode(String.self, forKey: .httpMethod)
        headers = try container.decode([String: String].self, forKey: .headers)
        secretHeaderNames = try container.decodeIfPresent([String].self, forKey: .secretHeaderNames) ?? []
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        workflowFilter = try container.decode([String].self, forKey: .workflowFilter)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(httpMethod, forKey: .httpMethod)
        try container.encode(headers, forKey: .headers)
        try container.encode(secretHeaderNames, forKey: .secretHeaderNames)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(workflowFilter, forKey: .workflowFilter)
    }
}

// MARK: - Delivery Log

struct ExampleDeliveryLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let webhookName: String
    let url: String
    let statusCode: Int?
    let error: String?
    let success: Bool
}

// MARK: - Webhook Service

final class ExampleWebhookService: ObservableObject, @unchecked Sendable {
    @Published var webhooks: [ExampleWebhookConfig] = []
    @Published var deliveryLog: [ExampleDeliveryLogEntry] = []

    private let configURL: URL
    private let maxLogEntries = 20
    let host: HostServices
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "api-key",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
        "x-webhook-secret",
        "webhook-secret",
        "x-hub-signature",
        "x-hub-signature-256",
        "x-signature",
        "signature",
        "x-signing-secret",
        "private-token",
        "token",
    ]

    init(dataDirectory: URL, host: HostServices) {
        self.host = host
        // pluginDataDirectory is automatically created by the host
        // at ~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/
        self.configURL = dataDirectory.appendingPathComponent("webhooks.json")
        loadConfig()
    }

    // MARK: - Persistence

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode([ExampleWebhookConfig].self, from: data) else { return }
        let migratedConfig = config.filter { !$0.isUnmodifiedDefaultDraft }
        webhooks = migratedConfig.map(resolveSecretHeaders)
        if migratedConfig.count != config.count
            || migratedConfig.contains(where: containsPlaintextSecretHeader)
            || migratedConfig.contains(where: containsEmptySensitiveHeader) {
            saveConfig()
        }
    }

    func saveConfig() {
        let persistedWebhooks = webhooks.map(configForPersistence)
        guard let data = try? JSONEncoder().encode(persistedWebhooks) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    func addWebhook(_ webhook: ExampleWebhookConfig) {
        webhooks.append(configRemovingEmptySensitiveHeaders(from: webhook))
        saveConfig()
    }

    func removeWebhook(id: UUID) {
        if let webhook = webhooks.first(where: { $0.id == id }) {
            clearStoredSecrets(for: webhook)
        }
        webhooks.removeAll { $0.id == id }
        saveConfig()
    }

    func updateWebhook(_ webhook: ExampleWebhookConfig) {
        guard let index = webhooks.firstIndex(where: { $0.id == webhook.id }) else { return }
        let nextWebhook = configRemovingEmptySensitiveHeaders(from: webhook)
        clearSecretsRemoved(from: webhooks[index], next: nextWebhook)
        webhooks[index] = nextWebhook
        saveConfig()
    }

    func saveWebhook(_ webhook: ExampleWebhookConfig) {
        if webhooks.contains(where: { $0.id == webhook.id }) {
            updateWebhook(webhook)
        } else {
            addWebhook(webhook)
        }
    }

    static func secretStorageKey(webhookID: UUID, headerName: String) -> String {
        let keyComponent = Data(normalizeHeaderName(headerName).utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "webhook.\(webhookID.uuidString).header.\(keyComponent)"
    }

    static func isSensitiveHeader(_ headerName: String) -> Bool {
        let normalized = normalizeHeaderName(headerName)
        return sensitiveHeaderNames.contains(normalized)
            || normalized.hasSuffix("-token")
            || normalized.hasSuffix("-secret")
            || normalized.hasSuffix("-api-key")
    }

    private static func normalizeHeaderName(_ headerName: String) -> String {
        headerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func containsPlaintextSecretHeader(_ webhook: ExampleWebhookConfig) -> Bool {
        webhook.headers.contains { headerName, value in
            Self.isSensitiveHeader(headerName)
                && value != ExampleWebhookConfig.secretHeaderPlaceholder
                && !value.isEmpty
        }
    }

    private func containsEmptySensitiveHeader(_ webhook: ExampleWebhookConfig) -> Bool {
        webhook.headers.contains { headerName, value in
            Self.isSensitiveHeader(headerName) && value.isEmpty
        }
    }

    private func resolveSecretHeaders(_ webhook: ExampleWebhookConfig) -> ExampleWebhookConfig {
        clearEmptySensitiveHeaderSecrets(in: webhook)
        var resolved = configRemovingEmptySensitiveHeaders(from: webhook)
        let secretHeaderNames = persistedSecretHeaderNames(for: resolved)

        for headerName in secretHeaderNames {
            let storageKey = Self.secretStorageKey(webhookID: webhook.id, headerName: headerName)
            if let secret = host.loadSecret(key: storageKey), !secret.isEmpty {
                resolved.headers[headerName] = secret
            } else if resolved.headers[headerName] == ExampleWebhookConfig.secretHeaderPlaceholder {
                resolved.headers.removeValue(forKey: headerName)
            }
        }

        resolved.secretHeaderNames = secretHeaderNames
        return resolved
    }

    private func configForPersistence(_ webhook: ExampleWebhookConfig) -> ExampleWebhookConfig {
        clearEmptySensitiveHeaderSecrets(in: webhook)
        var persisted = configRemovingEmptySensitiveHeaders(from: webhook)
        let secretHeaderNames = persistedSecretHeaderNames(for: persisted)

        for headerName in secretHeaderNames {
            guard let value = webhook.headers[headerName], !value.isEmpty else { continue }
            if value != ExampleWebhookConfig.secretHeaderPlaceholder {
                let storageKey = Self.secretStorageKey(webhookID: webhook.id, headerName: headerName)
                try? host.storeSecret(key: storageKey, value: value)
            }
            persisted.headers[headerName] = ExampleWebhookConfig.secretHeaderPlaceholder
        }

        persisted.secretHeaderNames = secretHeaderNames
        return persisted
    }

    private func configRemovingEmptySensitiveHeaders(from webhook: ExampleWebhookConfig) -> ExampleWebhookConfig {
        let emptySensitiveHeaderNames = Set(webhook.headers.compactMap { headerName, value in
            Self.isSensitiveHeader(headerName) && value.isEmpty ? Self.normalizeHeaderName(headerName) : nil
        })
        guard !emptySensitiveHeaderNames.isEmpty else { return webhook }

        var sanitized = webhook
        sanitized.headers = webhook.headers.filter { headerName, _ in
            !emptySensitiveHeaderNames.contains(Self.normalizeHeaderName(headerName))
        }
        sanitized.secretHeaderNames = webhook.secretHeaderNames.filter { headerName in
            !emptySensitiveHeaderNames.contains(Self.normalizeHeaderName(headerName))
        }
        return sanitized
    }

    private func clearEmptySensitiveHeaderSecrets(in webhook: ExampleWebhookConfig) {
        for (headerName, value) in webhook.headers where Self.isSensitiveHeader(headerName) && value.isEmpty {
            try? host.storeSecret(
                key: Self.secretStorageKey(webhookID: webhook.id, headerName: headerName),
                value: ""
            )
        }
    }

    private func persistedSecretHeaderNames(for webhook: ExampleWebhookConfig) -> [String] {
        var namesByNormalizedHeader: [String: String] = [:]
        for headerName in webhook.secretHeaderNames {
            namesByNormalizedHeader[Self.normalizeHeaderName(headerName)] = headerName
        }
        for headerName in webhook.headers.keys where Self.isSensitiveHeader(headerName) {
            namesByNormalizedHeader[Self.normalizeHeaderName(headerName)] = headerName
        }
        return namesByNormalizedHeader.values.sorted {
            Self.normalizeHeaderName($0) < Self.normalizeHeaderName($1)
        }
    }

    private func clearStoredSecrets(for webhook: ExampleWebhookConfig) {
        for headerName in persistedSecretHeaderNames(for: webhook) {
            try? host.storeSecret(
                key: Self.secretStorageKey(webhookID: webhook.id, headerName: headerName),
                value: ""
            )
        }
    }

    private func clearSecretsRemoved(from previous: ExampleWebhookConfig, next: ExampleWebhookConfig) {
        let nextNames = Set(persistedSecretHeaderNames(for: next).map(Self.normalizeHeaderName))
        for headerName in persistedSecretHeaderNames(for: previous)
            where !nextNames.contains(Self.normalizeHeaderName(headerName)) {
            try? host.storeSecret(
                key: Self.secretStorageKey(webhookID: previous.id, headerName: headerName),
                value: ""
            )
        }
    }

    // MARK: - Sending

    func sendWebhooks(for payload: TranscriptionCompletedPayload) async {
        for webhook in webhooks where webhook.isEnabled {
            // The event still exposes the legacy ruleName compatibility field.
            // An empty workflow filter means every completed transcription.
            if !webhook.workflowFilter.isEmpty {
                guard let ruleName = payload.ruleName,
                      webhook.workflowFilter.contains(ruleName) else {
                    continue
                }
            }
            await sendSingle(webhook, payload: payload)
        }
    }

    private func sendSingle(_ webhook: ExampleWebhookConfig, payload: TranscriptionCompletedPayload, isRetry: Bool = false) async {
        guard let url = URL(string: webhook.url) else {
            addLog(ExampleDeliveryLogEntry(webhookName: webhook.name, url: webhook.url,
                                           statusCode: nil, error: "Invalid URL", success: false))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = webhook.httpMethod
        request.timeoutInterval = 15
        for (key, value) in webhook.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await PluginHTTPClient.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let success = (200...299).contains(statusCode)

            addLog(ExampleDeliveryLogEntry(webhookName: webhook.name, url: webhook.url,
                                           statusCode: statusCode, error: nil, success: success))

            // Retry once after 5 seconds on failure
            if !success && !isRetry {
                try? await Task.sleep(for: .seconds(5))
                await sendSingle(webhook, payload: payload, isRetry: true)
            }
        } catch {
            addLog(ExampleDeliveryLogEntry(webhookName: webhook.name, url: webhook.url,
                                           statusCode: nil, error: error.localizedDescription, success: false))

            if !isRetry {
                try? await Task.sleep(for: .seconds(5))
                await sendSingle(webhook, payload: payload, isRetry: true)
            }
        }
    }

    private func addLog(_ entry: ExampleDeliveryLogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLog.insert(entry, at: 0)
            if self.deliveryLog.count > self.maxLogEntries {
                self.deliveryLog = Array(self.deliveryLog.prefix(self.maxLogEntries))
            }
        }
    }
}

// MARK: - Settings View

struct ExampleWebhookEditorPresentation {
    private(set) var editingWebhook: ExampleWebhookConfig?

    mutating func beginAddingWebhook() {
        editingWebhook = ExampleWebhookConfig()
    }

    mutating func beginEditingWebhook(_ webhook: ExampleWebhookConfig) {
        editingWebhook = webhook
    }

    mutating func dismissEditor() {
        editingWebhook = nil
    }
}

enum ExampleWebhookWorkflowScope: String, CaseIterable, Equatable {
    case allTranscriptions
    case selectedWorkflows
}

struct ExampleWebhookEditorState {
    var webhook: ExampleWebhookConfig
    var workflowScope: ExampleWebhookWorkflowScope

    init(webhook: ExampleWebhookConfig) {
        self.webhook = webhook
        self.workflowScope = webhook.workflowFilter.isEmpty ? .allTranscriptions : .selectedWorkflows
    }

    var canSave: Bool {
        guard !webhook.url.isEmpty else { return false }
        return workflowScope == .allTranscriptions || !webhook.workflowFilter.isEmpty
    }

    mutating func setWorkflow(_ name: String, isSelected: Bool) {
        if isSelected {
            guard !webhook.workflowFilter.contains(name) else { return }
            webhook.workflowFilter.append(name)
        } else {
            webhook.workflowFilter.removeAll { $0 == name }
        }
    }

    var webhookForSaving: ExampleWebhookConfig {
        guard workflowScope == .allTranscriptions else { return webhook }
        var updated = webhook
        updated.workflowFilter = []
        return updated
    }
}

struct ExampleWebhookSettingsView: View {
    @ObservedObject var service: ExampleWebhookService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginSettingsClose) private var closeSettings
    @State private var editorPresentation = ExampleWebhookEditorPresentation()

    private let bundle = Bundle(for: ExampleWebhookService.self)

    var body: some View {
        Group {
            if let editingWebhook = editorPresentation.editingWebhook {
                ExampleWebhookEditView(
                    webhook: editingWebhook,
                    availableWorkflows: service.host.availableRuleNames,
                    onSave: { updated in
                        service.saveWebhook(updated)
                        editorPresentation.dismissEditor()
                    },
                    onCancel: { editorPresentation.dismissEditor() }
                )
                .id(editingWebhook.id)
            } else {
                webhookOverview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerRelativeFrame(.vertical, alignment: .top)
        .frame(minHeight: 400)
    }

    private var webhookOverview: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Webhook Notifications", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    editorPresentation.beginAddingWebhook()
                } label: {
                    Label(String(localized: "Add Webhook", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.bar)

            Divider()

            if service.webhooks.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Webhooks", bundle: bundle), systemImage: "arrow.up.right.circle")
                } description: {
                    Text("Add a webhook to send transcription data to external services.", bundle: bundle)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(service.webhooks) { webhook in
                        WebhookRow(webhook: webhook, service: service, onEdit: {
                            editorPresentation.beginEditingWebhook(webhook)
                        })
                    }

                    if !service.deliveryLog.isEmpty {
                        Section(String(localized: "Delivery Log", bundle: bundle)) {
                            ForEach(service.deliveryLog) { entry in
                                DeliveryLogRow(entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done", bundle: bundle)) {
                    if let closeSettings {
                        closeSettings()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }
}

// MARK: - Webhook Row

private struct WebhookRow: View {
    let webhook: ExampleWebhookConfig
    let service: ExampleWebhookService
    let onEdit: () -> Void

    private let bundle = Bundle(for: ExampleWebhookService.self)

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(webhook.name.isEmpty ? webhook.url : webhook.name)
                    .font(.body.weight(.medium))

                if !webhook.url.isEmpty {
                    Text("\(webhook.httpMethod) \(webhook.url)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(workflowScopeDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { webhook.isEnabled },
                set: { enabled in
                    var updated = webhook
                    updated.isEnabled = enabled
                    service.updateWebhook(updated)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                service.removeWebhook(id: webhook.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var workflowScopeDescription: String {
        guard !webhook.workflowFilter.isEmpty else {
            return String(localized: "All transcriptions", bundle: bundle)
        }
        return String(
            format: String(localized: "Workflows: %@", bundle: bundle),
            webhook.workflowFilter.joined(separator: ", ")
        )
    }
}

// MARK: - Delivery Log Row

private struct DeliveryLogRow: View {
    let entry: ExampleDeliveryLogEntry

    private let bundle = Bundle(for: ExampleWebhookService.self)

    var body: some View {
        HStack {
            Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.success ? .green : .red)
            VStack(alignment: .leading) {
                Text(entry.webhookName.isEmpty ? entry.url : entry.webhookName)
                    .font(.caption)
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let code = entry.statusCode {
                Text("\(code)")
                    .font(.caption)
                    .monospacedDigit()
            }
            if let error = entry.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Edit View

private struct ExampleWebhookEditView: View {
    @State private var editorState: ExampleWebhookEditorState
    let availableWorkflows: [String]
    let onSave: (ExampleWebhookConfig) -> Void
    let onCancel: () -> Void

    private let bundle = Bundle(for: ExampleWebhookService.self)

    init(
        webhook: ExampleWebhookConfig,
        availableWorkflows: [String],
        onSave: @escaping (ExampleWebhookConfig) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _editorState = State(initialValue: ExampleWebhookEditorState(webhook: webhook))
        self.availableWorkflows = availableWorkflows
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(editorState.webhook.name.isEmpty && editorState.webhook.url.isEmpty
                     ? String(localized: "Add Webhook", bundle: bundle)
                     : String(localized: "Edit Webhook", bundle: bundle))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            ScrollView(.vertical) {
                Form {
                    Section(String(localized: "General", bundle: bundle)) {
                        TextField(
                            String(localized: "Name", bundle: bundle),
                            text: $editorState.webhook.name
                        )
                        TextField(
                            String(localized: "URL", bundle: bundle),
                            text: $editorState.webhook.url
                        )
                            .textContentType(.URL)
                        Picker(
                            String(localized: "Method", bundle: bundle),
                            selection: $editorState.webhook.httpMethod
                        ) {
                            Text("POST", bundle: bundle).tag("POST")
                            Text("PUT", bundle: bundle).tag("PUT")
                        }
                    }

                    Section(String(localized: "Workflows", bundle: bundle)) {
                        Picker(
                            String(localized: "Send webhook for", bundle: bundle),
                            selection: $editorState.workflowScope
                        ) {
                            Text("All transcriptions", bundle: bundle)
                                .tag(ExampleWebhookWorkflowScope.allTranscriptions)
                            Text("Selected workflows", bundle: bundle)
                                .tag(ExampleWebhookWorkflowScope.selectedWorkflows)
                        }
                        .pickerStyle(.radioGroup)

                        if editorState.workflowScope == .selectedWorkflows {
                            if availableWorkflows.isEmpty {
                                Text("No workflows configured.", bundle: bundle)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                ForEach(availableWorkflows, id: \.self) { name in
                                    Toggle(name, isOn: Binding(
                                        get: { editorState.webhook.workflowFilter.contains(name) },
                                        set: { selected in
                                            editorState.setWorkflow(name, isSelected: selected)
                                        }
                                    ))
                                }
                            }
                        }

                        Text(workflowScopeHelpText)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()

            // Footer
            HStack {
                Button(String(localized: "Cancel", bundle: bundle), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Save", bundle: bundle)) {
                    onSave(editorState.webhookForSaving)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editorState.canSave)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var workflowScopeHelpText: String {
        switch editorState.workflowScope {
        case .allTranscriptions:
            return String(
                localized: "The webhook is sent after every transcription, including transcriptions without a workflow.",
                bundle: bundle
            )
        case .selectedWorkflows where editorState.webhook.workflowFilter.isEmpty:
            return String(localized: "Select at least one workflow.", bundle: bundle)
        case .selectedWorkflows:
            return String(localized: "The webhook is sent only for the selected workflows.", bundle: bundle)
        }
    }
}
