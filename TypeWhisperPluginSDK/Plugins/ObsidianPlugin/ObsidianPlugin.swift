import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ObsidianPlugin)
final class ObsidianPlugin: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.obsidian"
    static let pluginName = "Obsidian"

    var actionName: String { "Save to Obsidian" }
    var actionId: String { "obsidian-save-note" }
    var actionIcon: String { "doc.text" }

    fileprivate var host: HostServices?
    private var subscriptionId: UUID?

    // Settings (cached from UserDefaults)
    fileprivate var _vaultPath: String = ""
    fileprivate var _subfolder: String = "TypeWhisper"
    fileprivate var _filenameTemplate: String = "{{DATE}} {{TIME}} {{APP}}"
    fileprivate var _dailyNoteEnabled: Bool = false
    fileprivate var _dailyNoteFormat: String = "{{DATE}}"
    fileprivate var _dailyNoteAppendTemplate: String = "## {{TIME}}\n\n{{TEXT}}"
    fileprivate var _frontmatterEnabled: Bool = true
    fileprivate var _frontmatterTags: [String] = ["typewhisper"]
    fileprivate var _autoExportEnabled: Bool = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        loadSettings()
        updateAutoExportSubscription()
    }

    func deactivate() {
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }
        host = nil
    }

    var isConfigured: Bool {
        !_vaultPath.isEmpty
    }

    // MARK: - Settings Persistence

    fileprivate func loadSettings() {
        _vaultPath = host?.userDefault(forKey: "vaultPath") as? String ?? ""
        _subfolder = host?.userDefault(forKey: "subfolder") as? String ?? "TypeWhisper"
        _filenameTemplate = host?.userDefault(forKey: "filenameTemplate") as? String ?? "{{DATE}} {{TIME}} {{APP}}"
        _dailyNoteEnabled = host?.userDefault(forKey: "dailyNoteEnabled") as? Bool ?? false
        _dailyNoteFormat = host?.userDefault(forKey: "dailyNoteFormat") as? String ?? "{{DATE}}"
        _dailyNoteAppendTemplate = host?.userDefault(forKey: "dailyNoteAppendTemplate") as? String ?? DailyNoteAppendPreset.timestamp.template
        _frontmatterEnabled = host?.userDefault(forKey: "frontmatterEnabled") as? Bool ?? true
        _frontmatterTags = host?.userDefault(forKey: "frontmatterTags") as? [String] ?? ["typewhisper"]
        _autoExportEnabled = host?.userDefault(forKey: "autoExportEnabled") as? Bool ?? false

        // Auto-detect vault if none set
        if _vaultPath.isEmpty {
            if let vaults = Self.detectVaults(), let first = vaults.first {
                _vaultPath = first.path
                host?.setUserDefault(_vaultPath, forKey: "vaultPath")
            }
        }
    }

    fileprivate func saveSetting(_ value: Any, forKey key: String) {
        host?.setUserDefault(value, forKey: key)
    }

    fileprivate func updateAutoExportSubscription() {
        // Remove existing subscription
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }

        guard _autoExportEnabled else { return }

        subscriptionId = host?.eventBus.subscribe { [weak self] event in
            switch event {
            case .transcriptionCompleted(let payload):
                await self?.autoExport(payload: payload)
            default:
                break
            }
        }
    }

    // MARK: - Vault Detection

    struct VaultInfo: Identifiable {
        let id: String
        let path: String
        let name: String
        let timestamp: Int
    }

    static func detectVaults() -> [VaultInfo]? {
        let obsidianConfigPath = NSHomeDirectory() + "/Library/Application Support/obsidian/obsidian.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: obsidianConfigPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else {
            return nil
        }

        var result: [VaultInfo] = []
        for (hash, info) in vaults {
            guard let path = info["path"] as? String else { continue }
            let name = (path as NSString).lastPathComponent
            let ts = info["ts"] as? Int ?? 0
            result.append(VaultInfo(id: hash, path: path, name: name, timestamp: ts))
        }
        return result.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - File Writing

    private func resolveTemplate(_ template: String, appName: String?, language: String?, timeFormat: String = "HH-mm-ss") -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = timeFormat

        var result = template
        result = result.replacingOccurrences(of: "{{DATE}}", with: dateFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{TIME}}", with: timeFormatter.string(from: now))
        result = result.replacingOccurrences(of: "{{APP}}", with: appName ?? "Unknown")
        result = result.replacingOccurrences(of: "{{LANG}}", with: language ?? "unknown")
        return result
    }

    private func resolveDailyNoteAppendTemplate(_ template: String, text: String, appName: String?, url: String?, language: String?) -> String {
        var result = resolveTemplate(template, appName: appName, language: language, timeFormat: "HH:mm")
        result = result.replacingOccurrences(of: "{{TEXT}}", with: text)
        result = result.replacingOccurrences(of: "{{URL}}", with: url ?? "")
        result = result.replacingOccurrences(of: "{{LANGUAGE}}", with: language ?? "unknown")
        return result
    }

    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return name.components(separatedBy: illegal).joined()
    }

    private func buildFrontmatter(appName: String?, bundleId: String?, url: String?, language: String?) -> String {
        var lines = ["---"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("date: \(formatter.string(from: Date()))")
        if let app = appName { lines.append("app: \(app)") }
        if let bid = bundleId { lines.append("bundleId: \(bid)") }
        if let u = url { lines.append("url: \(u)") }
        if let lang = language { lines.append("language: \(lang)") }
        if !_frontmatterTags.isEmpty {
            lines.append("tags:")
            for tag in _frontmatterTags {
                lines.append("  - \(tag)")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private func writeNote(text: String, appName: String?, bundleId: String?, url: String?, language: String?) throws -> String {
        guard !_vaultPath.isEmpty else {
            throw NSError(domain: "ObsidianPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "No vault configured"])
        }

        let fm = FileManager.default
        let subfolder = _subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath: String
        if subfolder.isEmpty {
            folderPath = _vaultPath
        } else {
            folderPath = (_vaultPath as NSString).appendingPathComponent(subfolder)
        }

        try fm.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

        if _dailyNoteEnabled {
            return try writeDailyNote(text: text, folderPath: folderPath, appName: appName, bundleId: bundleId, url: url, language: language)
        } else {
            return try writeNewNote(text: text, folderPath: folderPath, appName: appName, bundleId: bundleId, url: url, language: language)
        }
    }

    private func writeNewNote(text: String, folderPath: String, appName: String?, bundleId: String?, url: String?, language: String?) throws -> String {
        let resolvedName = resolveTemplate(_filenameTemplate, appName: appName, language: language)
        let sanitized = sanitizeFilename(resolvedName)
        let filename = sanitized.isEmpty ? "Note" : sanitized
        let filePath = (folderPath as NSString).appendingPathComponent("\(filename).md")

        var content = ""
        if _frontmatterEnabled {
            content += buildFrontmatter(appName: appName, bundleId: bundleId, url: url, language: language)
            content += "\n\n"
        }
        content += text

        // Handle duplicate filenames
        let finalPath = uniquePath(for: filePath)
        try content.write(toFile: finalPath, atomically: true, encoding: .utf8)

        return ((finalPath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func writeDailyNote(text: String, folderPath: String, appName: String?, bundleId: String?, url: String?, language: String?) throws -> String {
        let resolvedName = resolveTemplate(_dailyNoteFormat, appName: appName, language: language)
        let sanitized = sanitizeFilename(resolvedName)
        let filename = sanitized.isEmpty ? "Daily" : sanitized
        let filePath = (folderPath as NSString).appendingPathComponent("\(filename).md")

        let fm = FileManager.default
        let appendContent = resolveDailyNoteAppendTemplate(
            _dailyNoteAppendTemplate,
            text: text,
            appName: appName,
            url: url,
            language: language
        )

        if fm.fileExists(atPath: filePath) {
            // Append to existing daily note
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            handle.seekToEndOfFile()
            let separator: String
            if _dailyNoteAppendTemplate == DailyNoteAppendPreset.timestamp.template {
                // Preserve the legacy timestamp-section layout for existing daily notes.
                separator = "\n\n---\n\n\(appendContent)"
            } else if _dailyNoteAppendTemplate == DailyNoteAppendPreset.bullet.template {
                separator = "\n\(appendContent)"
            } else {
                separator = "\n\n\(appendContent)"
            }
            if let data = separator.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // Create new daily note
            var content = ""
            if _frontmatterEnabled {
                let includeAppMeta = _dailyNoteFormat.contains("{{APP}}")
                content += buildFrontmatter(
                    appName: includeAppMeta ? appName : nil,
                    bundleId: includeAppMeta ? bundleId : nil,
                    url: includeAppMeta ? url : nil,
                    language: language
                )
                content += "\n\n"
            }
            content += appendContent
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        return filename
    }

    private func uniquePath(for path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }

        let dir = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension

        var counter = 1
        while true {
            let candidate = (dir as NSString).appendingPathComponent("\(name) \(counter).\(ext)")
            if !fm.fileExists(atPath: candidate) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - ActionPlugin

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        guard isConfigured else {
            return ActionResult(success: false, message: "No Obsidian vault configured")
        }

        do {
            let noteName = try writeNote(
                text: input,
                appName: context.appName,
                bundleId: context.bundleIdentifier,
                url: context.url,
                language: context.language
            )
            return ActionResult(
                success: true,
                message: noteName,
                icon: "checkmark.circle.fill",
                displayDuration: 3
            )
        } catch {
            return ActionResult(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Auto-Export

    private func autoExport(payload: TranscriptionCompletedPayload) async {
        guard isConfigured else { return }
        let text = payload.finalText
        guard !text.isEmpty else { return }

        do {
            _ = try writeNote(
                text: text,
                appName: payload.appName,
                bundleId: payload.bundleIdentifier,
                url: payload.url,
                language: payload.language
            )
        } catch {
            print("[ObsidianPlugin] Auto-export failed: \(error)")
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(ObsidianSettingsView(plugin: self))
    }
}

// MARK: - Settings View

private struct ObsidianSettingsView: View {
    let plugin: ObsidianPlugin
    @State private var vaultPath: String = ""
    @State private var detectedVaults: [ObsidianPlugin.VaultInfo] = []
    @State private var subfolder: String = "TypeWhisper"
    @State private var filenameTemplate: String = "{{DATE}} {{TIME}} {{APP}}"
    @State private var dailyNoteEnabled: Bool = false
    @State private var dailyNoteFormat: String = "{{DATE}}"
    @State private var dailyNoteAppendTemplate: String = DailyNoteAppendPreset.timestamp.template
    @State private var frontmatterEnabled: Bool = true
    @State private var tagsInput: String = "typewhisper"
    @State private var autoExportEnabled: Bool = false
    private let bundle = pluginModuleBundle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Vault Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Vault", bundle: bundle)
                    .font(.headline)

                if !detectedVaults.isEmpty || !vaultPath.isEmpty {
                    Picker(String(localized: "Detected Vaults", bundle: bundle), selection: $vaultPath) {
                        Text("Select vault...", bundle: bundle).tag("")
                        ForEach(detectedVaults) { vault in
                            Text(vault.name).tag(vault.path)
                        }
                        if !vaultPath.isEmpty && !detectedVaults.contains(where: { $0.path == vaultPath }) {
                            let customName = (vaultPath as NSString).lastPathComponent
                            Text(customName).tag(vaultPath)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: vaultPath) { _, newValue in
                        plugin._vaultPath = newValue
                        plugin.saveSetting(newValue, forKey: "vaultPath")
                        plugin.host?.notifyCapabilitiesChanged()
                    }
                }

                HStack(spacing: 8) {
                    Text(vaultPath.isEmpty ? String(localized: "No vault selected", bundle: bundle) : vaultPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(String(localized: "Browse...", bundle: bundle)) {
                        selectVaultFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !vaultPath.isEmpty {
                Divider()

                // File Organization
                VStack(alignment: .leading, spacing: 8) {
                    Text("File Organization", bundle: bundle)
                        .font(.headline)

                    HStack {
                        Text("Subfolder:", bundle: bundle)
                            .frame(width: 100, alignment: .trailing)
                        TextField("TypeWhisper", text: $subfolder)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: subfolder) { _, newValue in
                                plugin._subfolder = newValue
                                plugin.saveSetting(newValue, forKey: "subfolder")
                            }
                    }

                    HStack {
                        Text("Filename:", bundle: bundle)
                            .frame(width: 100, alignment: .trailing)
                        TextField("{{DATE}} {{TIME}} {{APP}}", text: $filenameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: filenameTemplate) { _, newValue in
                                plugin._filenameTemplate = newValue
                                plugin.saveSetting(newValue, forKey: "filenameTemplate")
                            }
                    }

                    Text("Preview: \(previewFilename).md", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 108)

                    Text("Placeholders: {{DATE}}, {{TIME}}, {{APP}}, {{LANG}}", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 108)
                }

                Divider()

                // Daily Note
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $dailyNoteEnabled) {
                        VStack(alignment: .leading) {
                            Text("Daily Note Mode", bundle: bundle)
                                .font(.headline)
                            Text("Append all transcriptions to a single daily file instead of creating individual notes.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: dailyNoteEnabled) { _, newValue in
                        plugin._dailyNoteEnabled = newValue
                        plugin.saveSetting(newValue, forKey: "dailyNoteEnabled")
                    }

                    if dailyNoteEnabled {
                        HStack {
                            Text("Filename:", bundle: bundle)
                                .frame(width: 100, alignment: .trailing)
                            TextField("{{DATE}}", text: $dailyNoteFormat)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onChange(of: dailyNoteFormat) { _, newValue in
                                    plugin._dailyNoteFormat = newValue
                                    plugin.saveSetting(newValue, forKey: "dailyNoteFormat")
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Append format:", bundle: bundle)
                                    .frame(width: 100, alignment: .trailing)
                                Picker("Append format:", selection: appendFormatPreset) {
                                    Text("Timestamp section", bundle: bundle).tag(DailyNoteAppendPreset.timestamp.template)
                                    Text("Plain append", bundle: bundle).tag(DailyNoteAppendPreset.plain.template)
                                    Text("Bullet list", bundle: bundle).tag(DailyNoteAppendPreset.bullet.template)
                                    Text("Custom", bundle: bundle).tag(dailyNoteAppendTemplate)
                                }
                                .labelsHidden()
                            }

                            TextEditor(text: $dailyNoteAppendTemplate)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 84)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                                .onChange(of: dailyNoteAppendTemplate) { _, newValue in
                                    plugin._dailyNoteAppendTemplate = newValue
                                    plugin.saveSetting(newValue, forKey: "dailyNoteAppendTemplate")
                                }

                            Text("Placeholders: {{TEXT}}, {{TIME}}, {{DATE}}, {{APP}}, {{LANGUAGE}}, {{URL}}", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 108)
                        }
                    }
                }

                Divider()

                // Frontmatter
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $frontmatterEnabled) {
                        VStack(alignment: .leading) {
                            Text("YAML Frontmatter", bundle: bundle)
                                .font(.headline)
                            Text("Add metadata (date, app, language, tags) to each note.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: frontmatterEnabled) { _, newValue in
                        plugin._frontmatterEnabled = newValue
                        plugin.saveSetting(newValue, forKey: "frontmatterEnabled")
                    }

                    if frontmatterEnabled {
                        HStack {
                            Text("Tags:", bundle: bundle)
                                .frame(width: 100, alignment: .trailing)
                            TextField("typewhisper, meeting, voice", text: $tagsInput)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: tagsInput) { _, newValue in
                                    let tags = newValue.components(separatedBy: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                    plugin._frontmatterTags = tags
                                    plugin.saveSetting(tags, forKey: "frontmatterTags")
                                }
                        }
                    }
                }

                Divider()

                // Auto-Export
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $autoExportEnabled) {
                        VStack(alignment: .leading) {
                            Text("Auto-Export", bundle: bundle)
                                .font(.headline)
                            Text("Automatically save every transcription to Obsidian.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: autoExportEnabled) { _, newValue in
                        plugin._autoExportEnabled = newValue
                        plugin.saveSetting(newValue, forKey: "autoExportEnabled")
                        plugin.updateAutoExportSubscription()
                    }
                }

                Divider()

                // Recommended workflow instruction
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workflow Instruction", bundle: bundle)
                        .font(.headline)

                    Text("Create a Custom Workflow, paste this into Instruction, and set Action Target to \"Save to Obsidian\".", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let prompt = """
                    You are an assistant that formats spoken dictation into a clean Obsidian-compatible markdown note. Structure the text with appropriate headings, bullet points, and paragraphs. Fix grammar and remove filler words while preserving the original meaning. Output only the formatted markdown, no explanations.
                    """
                    Text(prompt)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)

                    Button(String(localized: "Copy Instruction", bundle: bundle)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .onAppear {
            vaultPath = plugin._vaultPath
            subfolder = plugin._subfolder
            filenameTemplate = plugin._filenameTemplate
            dailyNoteEnabled = plugin._dailyNoteEnabled
            dailyNoteFormat = plugin._dailyNoteFormat
            dailyNoteAppendTemplate = plugin._dailyNoteAppendTemplate
            frontmatterEnabled = plugin._frontmatterEnabled
            tagsInput = plugin._frontmatterTags.joined(separator: ", ")
            autoExportEnabled = plugin._autoExportEnabled
            detectedVaults = ObsidianPlugin.detectVaults() ?? []
        }
    }

    private var previewFilename: String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        let template = dailyNoteEnabled ? dailyNoteFormat : filenameTemplate
        return template
            .replacingOccurrences(of: "{{DATE}}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{{TIME}}", with: timeFormatter.string(from: now))
            .replacingOccurrences(of: "{{APP}}", with: "Safari")
            .replacingOccurrences(of: "{{LANG}}", with: "en")
    }

    private var appendFormatPreset: Binding<String> {
        Binding(
            get: { dailyNoteAppendTemplate },
            set: { dailyNoteAppendTemplate = $0 }
        )
    }

    private func selectVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select your Obsidian vault folder", bundle: bundle)
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
            plugin._vaultPath = url.path
            plugin.saveSetting(url.path, forKey: "vaultPath")
            plugin.host?.notifyCapabilitiesChanged()
        }
    }
}

private enum DailyNoteAppendPreset {
    case timestamp
    case plain
    case bullet

    var template: String {
        switch self {
        case .timestamp:
            "## {{TIME}}\n\n{{TEXT}}"
        case .plain:
            "{{TEXT}}"
        case .bullet:
            "- {{TEXT}}"
        }
    }
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: ObsidianPlugin.self)
#endif
}()
