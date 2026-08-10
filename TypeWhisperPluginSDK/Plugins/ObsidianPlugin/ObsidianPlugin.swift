import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

// MARK: - Plugin Entry Point

@objc(ObsidianPlugin)
final class ObsidianPlugin: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.obsidian"
    static let pluginName = "Obsidian"
    private static let historySyncActionID = "com.typewhisper.history.transcription-updated"
    private static let liveSyncEntryRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let liveSyncEntryLimit = 500

    var actionName: String { "Save to Obsidian" }
    var actionId: String { "obsidian-save-note" }
    var actionIcon: String { "doc.text" }

    fileprivate var host: HostServices?
    private var subscriptionId: UUID?

    // Settings (cached from UserDefaults)
    fileprivate var _vaultPath: String = ""
    fileprivate var _subfolder: String = "TypeWhisper"
    fileprivate var _filenameTemplate: String = "{{DATE}} {{TIME}} {{APP}}"
    fileprivate var _noteTemplate: String = "{{TRANSCRIPT}}"
    fileprivate var _dailyNoteEnabled: Bool = false
    fileprivate var _dailyNoteFormat: String = "{{DATE}}"
    fileprivate var _dailyNoteAppendTemplate: String = "## {{TIME}}\n\n{{TEXT}}"
    fileprivate var _frontmatterEnabled: Bool = true
    fileprivate var _frontmatterTags: [String] = ["typewhisper"]
    fileprivate var _autoExportEnabled: Bool = false
    fileprivate var _liveSyncEnabled: Bool = true
    private let liveSyncEntries = OSAllocatedUnfairLock(initialState: [String: LiveSyncEntry]())

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
        _noteTemplate = host?.userDefault(forKey: "noteTemplate") as? String ?? "{{TRANSCRIPT}}"
        _dailyNoteEnabled = host?.userDefault(forKey: "dailyNoteEnabled") as? Bool ?? false
        _dailyNoteFormat = host?.userDefault(forKey: "dailyNoteFormat") as? String ?? "{{DATE}}"
        _dailyNoteAppendTemplate = host?.userDefault(forKey: "dailyNoteAppendTemplate") as? String ?? DailyNoteAppendPreset.timestamp.template
        _frontmatterEnabled = host?.userDefault(forKey: "frontmatterEnabled") as? Bool ?? true
        _frontmatterTags = host?.userDefault(forKey: "frontmatterTags") as? [String] ?? ["typewhisper"]
        _autoExportEnabled = host?.userDefault(forKey: "autoExportEnabled") as? Bool ?? false
        _liveSyncEnabled = host?.userDefault(forKey: "liveSyncEnabled") as? Bool ?? true
        let storedEntries: [String: LiveSyncEntry]
        if let data = host?.userDefault(forKey: "liveSyncEntries") as? Data,
           let entries = try? JSONDecoder().decode([String: LiveSyncEntry].self, from: data) {
            storedEntries = entries
        } else {
            storedEntries = [:]
        }
        liveSyncEntries.withLock { entries in
            entries = storedEntries
            persistLiveSyncEntries(&entries)
        }

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

        guard _autoExportEnabled || _liveSyncEnabled else { return }

        subscriptionId = host?.eventBus.subscribe { [weak self] event in
            switch event {
            case .transcriptionCompleted(let payload):
                if self?._autoExportEnabled == true {
                    await self?.autoExport(payload: payload)
                } else if self?._liveSyncEnabled == true {
                    await self?.adoptMatchingActionExport(payload: payload)
                }
            case .actionCompleted(let payload) where payload.actionId == Self.historySyncActionID:
                guard self?._liveSyncEnabled == true else { return }
                await self?.liveSync(payload: payload)
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

    private struct HistorySyncPayload: Codable, Sendable {
        let id: UUID
        let rawText: String
        let finalText: String
        let language: String?
        let engineUsed: String
        let modelUsed: String?
        let durationSeconds: Double
        let appName: String?
        let bundleIdentifier: String?
        let url: String?
        let pipelineSteps: [String]
    }

    private struct NoteContext: Codable, Sendable {
        let timestamp: Date
        let rawText: String
        let finalText: String
        let appName: String?
        let bundleIdentifier: String?
        let url: String?
        let language: String?
        let engineUsed: String?
        let modelUsed: String?
        let durationSeconds: Double?
        let pipelineSteps: [String]

        init(input: String, actionContext: ActionContext) {
            timestamp = Date()
            rawText = actionContext.originalText.isEmpty ? input : actionContext.originalText
            finalText = input
            appName = actionContext.appName
            bundleIdentifier = actionContext.bundleIdentifier
            url = actionContext.url
            language = actionContext.language
            engineUsed = nil
            modelUsed = nil
            durationSeconds = nil
            pipelineSteps = []
        }

        init(_ payload: TranscriptionCompletedPayload) {
            timestamp = payload.timestamp
            rawText = payload.rawText
            finalText = payload.finalText
            appName = payload.appName
            bundleIdentifier = payload.bundleIdentifier
            url = payload.url
            language = payload.language
            engineUsed = payload.engineUsed
            modelUsed = payload.modelUsed
            durationSeconds = payload.durationSeconds
            pipelineSteps = []
        }

        init(_ payload: HistorySyncPayload, timestamp: Date) {
            self.timestamp = timestamp
            rawText = payload.rawText
            finalText = payload.finalText
            appName = payload.appName
            bundleIdentifier = payload.bundleIdentifier
            url = payload.url
            language = payload.language
            engineUsed = payload.engineUsed
            modelUsed = payload.modelUsed
            durationSeconds = payload.durationSeconds
            pipelineSteps = payload.pipelineSteps
        }
    }

    private struct LiveSyncEntry: Codable, Sendable {
        let path: String
        let context: NoteContext
        let awaitingCompletion: Bool
    }

    private struct WrittenNote {
        let name: String
        let path: String
    }

    private func resolveTemplate(
        _ template: String,
        context: NoteContext,
        timeFormat: String = "HH-mm-ss"
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = timeFormat

        var result = template
        let duration = context.durationSeconds.map {
            String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0)
        } ?? ""
        let values: [String: String] = [
            "APP": context.appName ?? "Unknown",
            "BUNDLE_ID": context.bundleIdentifier ?? "",
            "DATE": dateFormatter.string(from: context.timestamp),
            "DURATION": duration,
            "ENGINE": context.engineUsed ?? "",
            "LANG": context.language ?? "unknown",
            "LANGUAGE": context.language ?? "unknown",
            "MODEL": context.modelUsed ?? "",
            "PROCESSING": context.pipelineSteps.joined(separator: ", "),
            "RAW_TRANSCRIPT": context.rawText,
            "TEXT": context.finalText,
            "TIME": timeFormatter.string(from: context.timestamp),
            "TRANSCRIPT": context.finalText,
            "URL": context.url ?? "",
            "WORDS": String(context.finalText.split(whereSeparator: { $0.isWhitespace }).count),
        ]
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
            result = result.replacingOccurrences(of: "{{\(key.lowercased())}}", with: value)
        }
        return result
    }

    private func resolveDailyNoteAppendTemplate(_ template: String, context: NoteContext) -> String {
        resolveTemplate(template, context: context, timeFormat: "HH:mm")
    }

    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|[]")
            .union(.controlCharacters)
        return name
            .components(separatedBy: illegal)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildFrontmatter(context: NoteContext, includeAppMetadata: Bool = true) -> String {
        var lines = ["---"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("date: \(formatter.string(from: context.timestamp))")
        if includeAppMetadata, let app = context.appName { lines.append("app: \(yamlScalar(app))") }
        if includeAppMetadata, let bid = context.bundleIdentifier { lines.append("bundleId: \(yamlScalar(bid))") }
        if includeAppMetadata, let url = context.url { lines.append("url: \(yamlScalar(url))") }
        if let language = context.language { lines.append("language: \(yamlScalar(language))") }
        if let engine = context.engineUsed { lines.append("engine: \(yamlScalar(engine))") }
        if let model = context.modelUsed { lines.append("model: \(yamlScalar(model))") }
        if let duration = context.durationSeconds {
            lines.append("duration: \(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), duration))")
        }
        lines.append("words: \(context.finalText.split(whereSeparator: { $0.isWhitespace }).count)")
        if !context.pipelineSteps.isEmpty {
            lines.append("processing:")
            for step in context.pipelineSteps {
                lines.append("  - \(yamlScalar(step))")
            }
        }
        if !_frontmatterTags.isEmpty {
            lines.append("tags:")
            for tag in _frontmatterTags {
                lines.append("  - \(yamlScalar(tag))")
            }
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private func yamlScalar(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private func renderNote(context: NoteContext) -> String {
        var content = ""
        if _frontmatterEnabled {
            content += buildFrontmatter(context: context)
            content += "\n\n"
        }
        let template = _noteTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{{TRANSCRIPT}}"
            : _noteTemplate
        content += resolveTemplate(template, context: context)
        return content
    }

    private func writeNote(context: NoteContext) throws -> WrittenNote {
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
            return try writeDailyNote(context: context, folderPath: folderPath)
        } else {
            return try writeNewNote(context: context, folderPath: folderPath)
        }
    }

    private func writeNewNote(context: NoteContext, folderPath: String) throws -> WrittenNote {
        let resolvedName = resolveTemplate(_filenameTemplate, context: context)
        let sanitized = sanitizeFilename(resolvedName)
        let filename = sanitized.isEmpty ? "Note" : sanitized
        let filePath = (folderPath as NSString).appendingPathComponent("\(filename).md")

        // Handle duplicate filenames
        let finalPath = uniquePath(for: filePath)
        try renderNote(context: context).write(toFile: finalPath, atomically: true, encoding: .utf8)

        let name = ((finalPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return WrittenNote(name: name, path: finalPath)
    }

    private func writeDailyNote(context: NoteContext, folderPath: String) throws -> WrittenNote {
        let resolvedName = resolveTemplate(_dailyNoteFormat, context: context)
        let sanitized = sanitizeFilename(resolvedName)
        let filename = sanitized.isEmpty ? "Daily" : sanitized
        let filePath = (folderPath as NSString).appendingPathComponent("\(filename).md")

        let fm = FileManager.default
        let appendContent = resolveDailyNoteAppendTemplate(
            _dailyNoteAppendTemplate,
            context: context
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
                content += buildFrontmatter(context: context, includeAppMetadata: includeAppMeta)
                content += "\n\n"
            }
            content += appendContent
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        return WrittenNote(name: filename, path: filePath)
    }

    private func liveSyncKey(for timestamp: Date) -> String {
        String(timestamp.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    @discardableResult
    private func pruneLiveSyncEntries(_ entries: inout [String: LiveSyncEntry], now: Date = Date()) -> Bool {
        let originalCount = entries.count
        let cutoff = now.addingTimeInterval(-Self.liveSyncEntryRetention)
        entries = entries.filter { $0.value.context.timestamp >= cutoff }

        if entries.count > Self.liveSyncEntryLimit {
            entries = Dictionary(
                uniqueKeysWithValues: entries
                    .sorted { lhs, rhs in
                        if lhs.value.context.timestamp == rhs.value.context.timestamp {
                            return lhs.key < rhs.key
                        }
                        return lhs.value.context.timestamp > rhs.value.context.timestamp
                    }
                    .prefix(Self.liveSyncEntryLimit)
                    .map { ($0.key, $0.value) }
            )
        }
        return entries.count != originalCount
    }

    private func persistLiveSyncEntries(_ entries: inout [String: LiveSyncEntry]) {
        pruneLiveSyncEntries(&entries)
        guard let data = try? JSONEncoder().encode(entries) else {
            print("[ObsidianPlugin] Failed to persist live sync entries")
            return
        }
        saveSetting(data, forKey: "liveSyncEntries")
    }

    private func storeLiveSyncEntry(
        path: String,
        context: NoteContext,
        awaitingCompletion: Bool,
        entries: inout [String: LiveSyncEntry]
    ) {
        entries[liveSyncKey(for: context.timestamp)] = LiveSyncEntry(
            path: path,
            context: context,
            awaitingCompletion: awaitingCompletion
        )
        persistLiveSyncEntries(&entries)
    }

    private func removeLiveSyncEntry(forKey key: String, entries: inout [String: LiveSyncEntry]) {
        entries.removeValue(forKey: key)
        persistLiveSyncEntries(&entries)
    }

    private func matchingEntryKey(
        for context: NoteContext,
        requireMatchingFinalText: Bool,
        requireAwaitingCompletion: Bool = false,
        entries: [String: LiveSyncEntry]
    ) -> String? {
        let exactKey = liveSyncKey(for: context.timestamp)
        if let exactEntry = entries[exactKey],
           entryMatches(
               exactEntry,
               context: context,
               requireMatchingFinalText: requireMatchingFinalText,
               requireAwaitingCompletion: requireAwaitingCompletion
           ) {
            return exactKey
        }

        return entries
            .filter { _, entry in
                abs(entry.context.timestamp.timeIntervalSince(context.timestamp)) <= 60
                    && entryMatches(
                        entry,
                        context: context,
                        requireMatchingFinalText: requireMatchingFinalText,
                        requireAwaitingCompletion: requireAwaitingCompletion
                    )
            }
            .min { lhs, rhs in
                abs(lhs.value.context.timestamp.timeIntervalSince(context.timestamp))
                    < abs(rhs.value.context.timestamp.timeIntervalSince(context.timestamp))
            }?
            .key
    }

    private func entryMatches(
        _ entry: LiveSyncEntry,
        context: NoteContext,
        requireMatchingFinalText: Bool,
        requireAwaitingCompletion: Bool
    ) -> Bool {
        entry.context.rawText == context.rawText
            && entry.context.bundleIdentifier == context.bundleIdentifier
            && (!requireMatchingFinalText || entry.context.finalText == context.finalText)
            && (!requireAwaitingCompletion || entry.awaitingCompletion)
    }

    private func isInsideConfiguredVault(_ path: String) -> Bool {
        guard !_vaultPath.isEmpty else { return false }
        let vaultURL = URL(fileURLWithPath: _vaultPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let noteURL = URL(fileURLWithPath: path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let vaultComponents = vaultURL.pathComponents
        let noteComponents = noteURL.pathComponents
        guard noteComponents.count > vaultComponents.count,
              noteURL.pathExtension.compare("md", options: .caseInsensitive) == .orderedSame else {
            return false
        }

        let volumeIsCaseSensitive = (try? vaultURL.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames) ?? true
        return zip(vaultComponents, noteComponents).allSatisfy { vaultComponent, noteComponent in
            if volumeIsCaseSensitive {
                return vaultComponent == noteComponent
            }
            return vaultComponent.compare(noteComponent, options: .caseInsensitive) == .orderedSame
        }
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
            let noteContext = NoteContext(input: input, actionContext: context)
            let note = try liveSyncEntries.withLock { entries in
                let note = try writeNote(context: noteContext)
                if _liveSyncEnabled, !_dailyNoteEnabled {
                    storeLiveSyncEntry(
                        path: note.path,
                        context: noteContext,
                        awaitingCompletion: true,
                        entries: &entries
                    )
                }
                return note
            }
            return ActionResult(
                success: true,
                message: note.name,
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
            try liveSyncEntries.withLock { entries in
                if _liveSyncEnabled,
                   !_dailyNoteEnabled,
                   adoptMatchingActionExport(payload: payload, entries: &entries) {
                    return
                }
                let noteContext = NoteContext(payload)
                let note = try writeNote(context: noteContext)
                if _liveSyncEnabled, !_dailyNoteEnabled {
                    storeLiveSyncEntry(
                        path: note.path,
                        context: noteContext,
                        awaitingCompletion: false,
                        entries: &entries
                    )
                }
            }
        } catch {
            print("[ObsidianPlugin] Auto-export failed: \(error)")
        }
    }

    @discardableResult
    private func adoptMatchingActionExport(payload: TranscriptionCompletedPayload) async -> Bool {
        liveSyncEntries.withLock { entries in
            adoptMatchingActionExport(payload: payload, entries: &entries)
        }
    }

    private func adoptMatchingActionExport(
        payload: TranscriptionCompletedPayload,
        entries: inout [String: LiveSyncEntry]
    ) -> Bool {
        guard !_dailyNoteEnabled, isConfigured else { return false }
        let didPrune = pruneLiveSyncEntries(&entries)
        let completedContext = NoteContext(payload)
        guard let oldKey = matchingEntryKey(
            for: completedContext,
            requireMatchingFinalText: true,
            requireAwaitingCompletion: true,
            entries: entries
        ),
              let existingEntry = entries[oldKey] else {
            if didPrune {
                persistLiveSyncEntries(&entries)
            }
            return false
        }

        let newKey = liveSyncKey(for: completedContext.timestamp)
        let adoptedEntry = LiveSyncEntry(
            path: existingEntry.path,
            context: completedContext,
            awaitingCompletion: false
        )
        guard isInsideConfiguredVault(adoptedEntry.path),
              FileManager.default.fileExists(atPath: adoptedEntry.path) else {
            removeLiveSyncEntry(forKey: oldKey, entries: &entries)
            return false
        }

        do {
            try rewriteLiveSyncEntry(adoptedEntry)
            entries.removeValue(forKey: oldKey)
            entries[newKey] = adoptedEntry
            persistLiveSyncEntries(&entries)
            return true
        } catch {
            print("[ObsidianPlugin] Failed to associate an action export with its transcription: \(error)")
            return false
        }
    }

    private func liveSync(payload: ActionCompletedPayload) async {
        guard !_dailyNoteEnabled,
              payload.success,
              let data = payload.message.data(using: .utf8),
              let update = try? JSONDecoder().decode(HistorySyncPayload.self, from: data) else { return }

        let updatedContext = NoteContext(update, timestamp: payload.timestamp)
        liveSyncEntries.withLock { entries in
            let didPrune = pruneLiveSyncEntries(&entries)
            guard let oldKey = matchingEntryKey(
                for: updatedContext,
                requireMatchingFinalText: false,
                entries: entries
            ),
                  let existingEntry = entries[oldKey] else {
                if didPrune {
                    persistLiveSyncEntries(&entries)
                }
                return
            }
            guard isInsideConfiguredVault(existingEntry.path) else {
                removeLiveSyncEntry(forKey: oldKey, entries: &entries)
                print("[ObsidianPlugin] Live sync ignored a note path outside the configured vault")
                return
            }

            do {
                let updatedEntry = LiveSyncEntry(
                    path: existingEntry.path,
                    context: updatedContext,
                    awaitingCompletion: false
                )
                try rewriteLiveSyncEntry(updatedEntry)
                let newKey = liveSyncKey(for: updatedContext.timestamp)
                entries.removeValue(forKey: oldKey)
                entries[newKey] = updatedEntry
                persistLiveSyncEntries(&entries)
            } catch {
                print("[ObsidianPlugin] Live sync failed: \(error)")
            }
        }
    }

    private func rewriteLiveSyncEntry(_ entry: LiveSyncEntry) throws {
        let noteURL = URL(fileURLWithPath: entry.path)
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try renderNote(context: entry.context).write(
            to: noteURL,
            atomically: true,
            encoding: .utf8
        )
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
    @State private var noteTemplate: String = "{{TRANSCRIPT}}"
    @State private var dailyNoteEnabled: Bool = false
    @State private var dailyNoteFormat: String = "{{DATE}}"
    @State private var dailyNoteAppendTemplate: String = DailyNoteAppendPreset.timestamp.template
    @State private var appendFormatSelection: String = DailyNoteAppendPreset.timestamp.template
    @State private var frontmatterEnabled: Bool = true
    @State private var tagsInput: String = "typewhisper"
    @State private var autoExportEnabled: Bool = false
    @State private var liveSyncEnabled: Bool = true
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

                    Text("Placeholders: {{DATE}}, {{TIME}}, {{APP}}, {{LANGUAGE}}", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 108)

                    if !dailyNoteEnabled {
                        Text("Note Template", bundle: bundle)
                            .font(.subheadline.weight(.medium))
                            .padding(.top, 4)

                        TextEditor(text: $noteTemplate)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 112)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .onChange(of: noteTemplate) { _, newValue in
                                plugin._noteTemplate = newValue
                                plugin.saveSetting(newValue, forKey: "noteTemplate")
                            }

                        Text("Placeholders: {{TRANSCRIPT}}, {{RAW_TRANSCRIPT}}, {{DATE}}, {{TIME}}, {{APP}}, {{LANGUAGE}}, {{URL}}, {{ENGINE}}, {{MODEL}}, {{DURATION}}, {{WORDS}}", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
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
                                Picker("Append format:", selection: $appendFormatSelection) {
                                    Text("Timestamp section", bundle: bundle).tag(DailyNoteAppendPreset.timestamp.template)
                                    Text("Plain append", bundle: bundle).tag(DailyNoteAppendPreset.plain.template)
                                    Text("Bullet list", bundle: bundle).tag(DailyNoteAppendPreset.bullet.template)
                                    Text("Custom", bundle: bundle).tag(DailyNoteAppendPreset.customSelection)
                                }
                                .labelsHidden()
                                .onChange(of: appendFormatSelection) { _, newValue in
                                    guard newValue != DailyNoteAppendPreset.customSelection else { return }
                                    dailyNoteAppendTemplate = newValue
                                }
                            }

                            TextEditor(text: $dailyNoteAppendTemplate)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 84)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                                .onChange(of: dailyNoteAppendTemplate) { _, newValue in
                                    plugin._dailyNoteAppendTemplate = newValue
                                    plugin.saveSetting(newValue, forKey: "dailyNoteAppendTemplate")
                                    appendFormatSelection = DailyNoteAppendPreset.selection(for: newValue)
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

                    Toggle(isOn: $liveSyncEnabled) {
                        VStack(alignment: .leading) {
                            Text("Live Sync History Edits", bundle: bundle)
                                .font(.headline)
                            Text("Keep exported individual notes up to date when their transcript is edited in TypeWhisper. External Obsidian edits may be overwritten.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(dailyNoteEnabled)
                    .onChange(of: liveSyncEnabled) { _, newValue in
                        plugin._liveSyncEnabled = newValue
                        plugin.saveSetting(newValue, forKey: "liveSyncEnabled")
                        plugin.updateAutoExportSubscription()
                    }

                    if dailyNoteEnabled {
                        Text("Live Sync is available for individual notes only.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            noteTemplate = plugin._noteTemplate
            dailyNoteEnabled = plugin._dailyNoteEnabled
            dailyNoteFormat = plugin._dailyNoteFormat
            dailyNoteAppendTemplate = plugin._dailyNoteAppendTemplate
            appendFormatSelection = DailyNoteAppendPreset.selection(for: dailyNoteAppendTemplate)
            frontmatterEnabled = plugin._frontmatterEnabled
            tagsInput = plugin._frontmatterTags.joined(separator: ", ")
            autoExportEnabled = plugin._autoExportEnabled
            liveSyncEnabled = plugin._liveSyncEnabled
            detectedVaults = ObsidianPlugin.detectVaults() ?? []
        }
    }

    private var previewFilename: String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = Calendar(identifier: .gregorian)
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH-mm-ss"

        let template = dailyNoteEnabled ? dailyNoteFormat : filenameTemplate
        return template
            .replacingOccurrences(of: "{{DATE}}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{{TIME}}", with: timeFormatter.string(from: now))
            .replacingOccurrences(of: "{{APP}}", with: "Safari")
            .replacingOccurrences(of: "{{LANGUAGE}}", with: "en")
            .replacingOccurrences(of: "{{LANG}}", with: "en")
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

    static let customSelection = "custom"

    static var templates: [String] {
        [timestamp.template, plain.template, bullet.template]
    }

    static func selection(for template: String) -> String {
        templates.contains(template) ? template : customSelection
    }

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
