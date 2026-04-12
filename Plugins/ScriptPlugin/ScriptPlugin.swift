import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ScriptPlugin)
final class ScriptPlugin: NSObject, PostProcessorPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.script"
    static let pluginName = "Script Runner"

    let processorName = "Script Runner"
    let priority = 400

    private var host: HostServices?
    private var service: ScriptService?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        self.service = ScriptService(dataDirectory: host.pluginDataDirectory, host: host)
    }

    func deactivate() {
        host = nil
        service = nil
    }

    var settingsView: AnyView? {
        guard let service else { return nil }
        return AnyView(ScriptSettingsView(service: service))
    }

    @MainActor
    func process(text: String, context: PostProcessingContext) async throws -> String {
        guard let service else { return text }
        let scripts = service.scripts.filter { $0.isEnabled }
        guard !scripts.isEmpty else { return text }

        var result = text
        for script in scripts {
            // Rule filter: empty = all, otherwise match by name
            if !script.profileFilter.isEmpty {
                guard let ruleName = context.ruleName,
                      script.profileFilter.contains(ruleName) else {
                    continue
                }
            }
            result = await service.executeScript(script, input: result, context: context)
        }
        return result
    }
}

// MARK: - Script Config Model

struct ScriptConfig: Codable, Identifiable {
    var id: UUID
    var name: String
    var command: String
    var isEnabled: Bool
    var profileFilter: [String]

    init(name: String = "", command: String = "", isEnabled: Bool = true, profileFilter: [String] = []) {
        self.id = UUID()
        self.name = name
        self.command = command
        self.isEnabled = isEnabled
        self.profileFilter = profileFilter
    }
}

// MARK: - Execution Log

struct ExecutionLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let scriptName: String
    let success: Bool
    let durationMs: Int
    let errorMessage: String?
}

// MARK: - Script Service

final class ScriptService: ObservableObject, @unchecked Sendable {
    @Published var scripts: [ScriptConfig] = []
    @Published var executionLog: [ExecutionLogEntry] = []

    private let configURL: URL
    private let maxLogEntries = 20
    let host: HostServices

    init(dataDirectory: URL, host: HostServices) {
        self.host = host
        self.configURL = dataDirectory.appendingPathComponent("scripts.json")
        loadConfig()
    }

    // MARK: - Persistence

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode([ScriptConfig].self, from: data) else { return }
        scripts = config
    }

    func saveConfig() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    func addScript(_ script: ScriptConfig) {
        scripts.append(script)
        saveConfig()
    }

    func removeScript(id: UUID) {
        scripts.removeAll { $0.id == id }
        saveConfig()
    }

    func updateScript(_ script: ScriptConfig) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        saveConfig()
    }

    func addExampleScript() {
        addScript(ScriptConfig(
            name: "UPPERCASE Example",
            command: "tr '[:lower:]' '[:upper:]'",
            isEnabled: true
        ))
    }

    // MARK: - Execution

    func executeScript(_ script: ScriptConfig, input: String, context: PostProcessingContext) async -> String {
        let start = Date()

        do {
            let output = try await runProcess(command: script.command, input: input, context: context)
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            addLog(ExecutionLogEntry(scriptName: script.name, success: true, durationMs: durationMs, errorMessage: nil))
            return output
        } catch {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            addLog(ExecutionLogEntry(scriptName: script.name, success: false, durationMs: durationMs, errorMessage: error.localizedDescription))
            return input
        }
    }

    private func runProcess(command: String, input: String, context: PostProcessingContext) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]

                // Environment: inherit system + add TypeWhisper context + ensure UTF-8
                var env = ProcessInfo.processInfo.environment
                // Ensure UTF-8 locale for correct multi-byte character handling (e.g. tr with umlauts)
                if env["LANG"] == nil && env["LC_ALL"] == nil {
                    env["LANG"] = "en_US.UTF-8"
                }
                if let appName = context.appName { env["TYPEWHISPER_APP_NAME"] = appName }
                if let bundleId = context.bundleIdentifier { env["TYPEWHISPER_BUNDLE_ID"] = bundleId }
                if let url = context.url { env["TYPEWHISPER_URL"] = url }
                if let language = context.language { env["TYPEWHISPER_LANGUAGE"] = language }
                if let ruleName = context.ruleName {
                    env["TYPEWHISPER_RULE"] = ruleName
                    env["TYPEWHISPER_PROFILE"] = ruleName
                }
                if let selectedText = context.selectedText { env["TYPEWHISPER_SELECTED_TEXT"] = selectedText }
                process.environment = env

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Read stdout/stderr incrementally to prevent pipe deadlocks
                let stdoutData = OSAllocatedUnfairLock(initialState: Data())
                let stderrData = OSAllocatedUnfairLock(initialState: Data())

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    stdoutData.withLock { $0.append(data) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    stderrData.withLock { $0.append(data) }
                }

                // Timeout after 5 seconds
                let didTimeout = OSAllocatedUnfairLock(initialState: false)
                let timeoutWork = DispatchWorkItem { [weak process] in
                    didTimeout.withLock { $0 = true }
                    process?.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutWork)

                do {
                    try process.run()

                    // Write input to stdin
                    let inputData = input.data(using: .utf8) ?? Data()
                    stdinPipe.fileHandleForWriting.write(inputData)
                    stdinPipe.fileHandleForWriting.closeFile()

                    process.waitUntilExit()
                    timeoutWork.cancel()

                    // Stop readability handlers
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    // Read any remaining data
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    stdoutData.withLock { $0.append(remainingStdout) }

                    if didTimeout.withLock({ $0 }) {
                        continuation.resume(throwing: ScriptError.timeout)
                        return
                    }

                    if process.terminationStatus != 0 {
                        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        stderrData.withLock { $0.append(remainingStderr) }
                        let stderrStr = stderrData.withLock {
                            String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        continuation.resume(throwing: ScriptError.nonZeroExit(
                            code: process.terminationStatus,
                            stderr: stderrStr
                        ))
                        return
                    }

                    let finalOutput = stdoutData.withLock { $0 }

                    guard var output = String(data: finalOutput, encoding: .utf8), !output.isEmpty else {
                        continuation.resume(throwing: ScriptError.emptyOutput)
                        return
                    }

                    // Trim only trailing newline (scripts often append one)
                    if output.hasSuffix("\n") {
                        output = String(output.dropLast())
                    }

                    // Remove null bytes that can crash CoreData/SwiftData during save
                    output = output.replacingOccurrences(of: "\0", with: "")

                    guard !output.isEmpty else {
                        continuation.resume(throwing: ScriptError.emptyOutput)
                        return
                    }

                    continuation.resume(returning: output)
                } catch {
                    timeoutWork.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func addLog(_ entry: ExecutionLogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.executionLog.insert(entry, at: 0)
            if self.executionLog.count > self.maxLogEntries {
                self.executionLog = Array(self.executionLog.prefix(self.maxLogEntries))
            }
        }
    }
}

// MARK: - Errors

enum ScriptError: LocalizedError {
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Script timed out after 5 seconds"
        case .nonZeroExit(let code, let stderr):
            return "Exit code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .emptyOutput:
            return "Script produced no output"
        }
    }
}

// MARK: - Settings View

struct ScriptSettingsView: View {
    @ObservedObject var service: ScriptService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pluginSettingsClose) private var closeSettings
    @State private var editingScript: ScriptConfig?

    private let bundle = Bundle(for: ScriptService.self)

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Script Runner", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button {
                    service.addExampleScript()
                } label: {
                    Label(String(localized: "Add Example", bundle: bundle), systemImage: "text.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    service.addScript(ScriptConfig())
                } label: {
                    Label(String(localized: "Add Script", bundle: bundle), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.bar)

            Divider()

            if service.scripts.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Scripts", bundle: bundle), systemImage: "terminal")
                } description: {
                    Text("Add a script to process transcribed text via shell commands.", bundle: bundle)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(service.scripts) { script in
                        ScriptRow(script: script, service: service, onEdit: {
                            editingScript = script
                        })
                    }

                    if !service.executionLog.isEmpty {
                        Section(String(localized: "Execution Log", bundle: bundle)) {
                            ForEach(service.executionLog) { entry in
                                ExecutionLogRow(entry: entry)
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
        .sheet(item: $editingScript) { script in
            ScriptEditView(
                script: script,
                availableProfiles: service.host.availableRuleNames,
                onSave: { updated in
                    service.updateScript(updated)
                    editingScript = nil
                },
                onCancel: { editingScript = nil }
            )
        }
    }
}

// MARK: - Script Row

private struct ScriptRow: View {
    let script: ScriptConfig
    let service: ScriptService
    let onEdit: () -> Void

    private let bundle = Bundle(for: ScriptService.self)

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name.isEmpty ? script.command : script.name)
                    .font(.body.weight(.medium))

                if !script.command.isEmpty {
                    Text(script.command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !script.profileFilter.isEmpty {
                    Text("Rules: \(script.profileFilter.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { script.isEnabled },
                set: { enabled in
                    var updated = script
                    updated.isEnabled = enabled
                    service.updateScript(updated)
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
                service.removeScript(id: script.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Execution Log Row

private struct ExecutionLogRow: View {
    let entry: ExecutionLogEntry

    var body: some View {
        HStack {
            Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.success ? .green : .red)
            VStack(alignment: .leading) {
                Text(entry.scriptName)
                    .font(.caption)
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(entry.durationMs)ms")
                .font(.caption)
                .monospacedDigit()
            if let error = entry.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Edit View

private struct ScriptEditView: View {
    @State var script: ScriptConfig
    let availableProfiles: [String]
    let onSave: (ScriptConfig) -> Void
    let onCancel: () -> Void

    private let bundle = Bundle(for: ScriptService.self)

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(script.name.isEmpty && script.command.isEmpty
                     ? String(localized: "Add Script", bundle: bundle)
                     : String(localized: "Edit Script", bundle: bundle))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section(String(localized: "General", bundle: bundle)) {
                    TextField(String(localized: "Name", bundle: bundle), text: $script.name)
                    VStack(alignment: .leading) {
                        Text("Command", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $script.command)
                            .font(.body.monospaced())
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Text is passed via stdin. Return result via stdout.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Rules") {
                    if availableProfiles.isEmpty {
                        Text("No rules configured.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(availableProfiles, id: \.self) { name in
                            Toggle(name, isOn: Binding(
                                get: { script.profileFilter.contains(name) },
                                set: { selected in
                                    if selected {
                                        script.profileFilter.append(name)
                                    } else {
                                        script.profileFilter.removeAll { $0 == name }
                                    }
                                }
                            ))
                        }
                    }

                    Text(script.profileFilter.isEmpty
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
                    onSave(script)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(script.command.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
    }
}
