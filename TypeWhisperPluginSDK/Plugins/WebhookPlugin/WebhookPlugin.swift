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
    var id: UUID
    var name: String
    var url: String
    var httpMethod: String
    var headers: [String: String]
    var isEnabled: Bool
    var profileFilter: [String]  // Empty = all rules

    init(name: String = "", url: String = "", httpMethod: String = "POST",
         headers: [String: String] = ["Content-Type": "application/json"],
         isEnabled: Bool = true, profileFilter: [String] = []) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.httpMethod = httpMethod
        self.headers = headers
        self.isEnabled = isEnabled
        self.profileFilter = profileFilter
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
        webhooks = config
    }

    func saveConfig() {
        guard let data = try? JSONEncoder().encode(webhooks) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    func addWebhook(_ webhook: ExampleWebhookConfig) {
        webhooks.append(webhook)
        saveConfig()
    }

    func removeWebhook(id: UUID) {
        webhooks.removeAll { $0.id == id }
        saveConfig()
    }

    func updateWebhook(_ webhook: ExampleWebhookConfig) {
        guard let index = webhooks.firstIndex(where: { $0.id == webhook.id }) else { return }
        webhooks[index] = webhook
        saveConfig()
    }

    // MARK: - Sending

    func sendWebhooks(for payload: TranscriptionCompletedPayload) async {
        for webhook in webhooks where webhook.isEnabled {
            // Rule filter: empty = all, otherwise match by name
            if !webhook.profileFilter.isEmpty {
                guard let ruleName = payload.ruleName,
                      webhook.profileFilter.contains(ruleName) else {
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

struct ExampleWebhookSettingsView: View {
    @ObservedObject var service: ExampleWebhookService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginSettingsClose) private var closeSettings
    @State private var editingWebhook: ExampleWebhookConfig?

    private let bundle = Bundle(for: ExampleWebhookService.self)

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Webhook Notifications", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    service.addWebhook(ExampleWebhookConfig())
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
                            editingWebhook = webhook
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
        .sheet(item: $editingWebhook) { webhook in
            ExampleWebhookEditView(
                webhook: webhook,
                availableProfiles: service.host.availableRuleNames,
                onSave: { updated in
                    service.updateWebhook(updated)
                    editingWebhook = nil
                },
                onCancel: { editingWebhook = nil }
            )
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
                if !webhook.profileFilter.isEmpty {
                    Text("Rules: \(webhook.profileFilter.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
    @State var webhook: ExampleWebhookConfig
    let availableProfiles: [String]
    let onSave: (ExampleWebhookConfig) -> Void
    let onCancel: () -> Void

    private let bundle = Bundle(for: ExampleWebhookService.self)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(webhook.name.isEmpty && webhook.url.isEmpty
                     ? String(localized: "Add Webhook", bundle: bundle)
                     : String(localized: "Edit Webhook", bundle: bundle))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section(String(localized: "General", bundle: bundle)) {
                    TextField(String(localized: "Name", bundle: bundle), text: $webhook.name)
                    TextField(String(localized: "URL", bundle: bundle), text: $webhook.url)
                        .textContentType(.URL)
                    Picker(String(localized: "Method", bundle: bundle), selection: $webhook.httpMethod) {
                        Text("POST", bundle: bundle).tag("POST")
                        Text("PUT", bundle: bundle).tag("PUT")
                    }
                }

                Section("Rules") {
                    if availableProfiles.isEmpty {
                        Text("No rules configured.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(availableProfiles, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { webhook.profileFilter.contains(name) },
                                set: { selected in
                                    if selected {
                                        webhook.profileFilter.append(name)
                                    } else {
                                        webhook.profileFilter.removeAll { $0 == name }
                                    }
                                }
                            ))
                        }
                    }

                    Text(webhook.profileFilter.isEmpty
                         ? String(localized: "Active for all transcriptions.", bundle: bundle)
                         : "Only active for selected rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Button(String(localized: "Cancel", bundle: bundle), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Save", bundle: bundle)) {
                    onSave(webhook)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(webhook.url.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
    }
}
