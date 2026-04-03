import Foundation
import SwiftUI

// MARK: - Base Plugin Protocol

public protocol TypeWhisperPlugin: AnyObject, Sendable {
    static var pluginId: String { get }
    static var pluginName: String { get }

    init()
    func activate(host: HostServices)
    func deactivate()
    var settingsView: AnyView? { get }
}

public extension TypeWhisperPlugin {
    var settingsView: AnyView? { nil }
}

// MARK: - Shared Settings Activity

public struct PluginSettingsActivity: Sendable, Equatable {
    public let message: String
    public let progress: Double?
    public let isError: Bool

    public init(message: String, progress: Double? = nil, isError: Bool = false) {
        self.message = message
        self.progress = progress
        self.isError = isError
    }
}

public protocol PluginSettingsActivityReporting: TypeWhisperPlugin {
    var currentSettingsActivity: PluginSettingsActivity? { get }
}

public extension PluginSettingsActivityReporting {
    var currentSettingsActivity: PluginSettingsActivity? { nil }
}

// MARK: - Settings Window Environment

private struct PluginSettingsCloseActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

public extension EnvironmentValues {
    var pluginSettingsClose: (@MainActor @Sendable () -> Void)? {
        get { self[PluginSettingsCloseActionKey.self] }
        set { self[PluginSettingsCloseActionKey.self] = newValue }
    }
}

// MARK: - LLM Provider Plugin

public final class PluginModelInfo: @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let sizeDescription: String
    public let languageCount: Int

    public init(id: String, displayName: String, sizeDescription: String = "", languageCount: Int = 0) {
        self.id = id
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.languageCount = languageCount
    }
}

public protocol LLMProviderPlugin: TypeWhisperPlugin {
    var providerName: String { get }
    var isAvailable: Bool { get }
    var supportedModels: [PluginModelInfo] { get }
    func process(systemPrompt: String, userText: String, model: String?) async throws -> String
}

/// Optional protocol for LLM plugins that expose their selected model.
/// Kept separate from LLMProviderPlugin to preserve binary compatibility with existing plugins.
@objc public protocol LLMModelSelectable {
    @objc optional var preferredModelId: String? { get }
}

// MARK: - Post-Processor Plugin

public struct PostProcessingContext: Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let url: String?
    public let language: String?
    public let profileName: String?
    public let selectedText: String?

    public init(appName: String? = nil, bundleIdentifier: String? = nil, url: String? = nil, language: String? = nil, profileName: String? = nil, selectedText: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.language = language
        self.profileName = profileName
        self.selectedText = selectedText
    }
}

public protocol PostProcessorPlugin: TypeWhisperPlugin {
    var processorName: String { get }
    var priority: Int { get }
    @MainActor func process(text: String, context: PostProcessingContext) async throws -> String
}

// MARK: - Transcription Engine Plugin

public struct AudioData: Sendable {
    public let samples: [Float]       // 16kHz mono
    public let wavData: Data          // Pre-encoded WAV
    public let duration: TimeInterval

    public init(samples: [Float], wavData: Data, duration: TimeInterval) {
        self.samples = samples
        self.wavData = wavData
        self.duration = duration
    }
}

public struct PluginTranscriptionSegment: Sendable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct PluginTranscriptionResult: Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let segments: [PluginTranscriptionSegment]

    public init(text: String, detectedLanguage: String? = nil, segments: [PluginTranscriptionSegment] = []) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.segments = segments
    }
}

public protocol TranscriptionEnginePlugin: TypeWhisperPlugin {
    var providerId: String { get }
    var providerDisplayName: String { get }
    var isConfigured: Bool { get }
    var transcriptionModels: [PluginModelInfo] { get }
    var selectedModelId: String? { get }
    func selectModel(_ modelId: String)
    var supportsTranslation: Bool { get }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult

    var supportsStreaming: Bool { get }
    var supportedLanguages: [String] { get }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?,
                    onProgress: @Sendable @escaping (String) -> Bool) async throws -> PluginTranscriptionResult
}

public extension TranscriptionEnginePlugin {
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { [] }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?,
                    onProgress: @Sendable @escaping (String) -> Bool) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
    }
}

// MARK: - Action Plugin

public struct ActionContext: Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let url: String?
    public let language: String?
    public let originalText: String

    public init(appName: String? = nil, bundleIdentifier: String? = nil,
                url: String? = nil, language: String? = nil, originalText: String = "") {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.language = language
        self.originalText = originalText
    }
}

public struct ActionResult: Sendable {
    public let success: Bool
    public let message: String
    public let url: String?
    public let icon: String?
    public let displayDuration: TimeInterval?

    public init(success: Bool, message: String, url: String? = nil, icon: String? = nil, displayDuration: TimeInterval? = nil) {
        self.success = success
        self.message = message
        self.url = url
        self.icon = icon
        self.displayDuration = displayDuration
    }
}

public protocol ActionPlugin: TypeWhisperPlugin {
    var actionName: String { get }
    var actionId: String { get }
    var actionIcon: String { get }
    func execute(input: String, context: ActionContext) async throws -> ActionResult
}

// MARK: - Memory Storage Plugin

public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case fact
    case preference
    case pattern
    case correction
    case context
    case instruction
}

public struct MemorySource: Codable, Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let profileName: String?
    public let timestamp: Date

    public init(appName: String? = nil, bundleIdentifier: String? = nil,
                profileName: String? = nil, timestamp: Date = Date()) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.profileName = profileName
        self.timestamp = timestamp
    }
}

public struct MemoryEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public var content: String
    public let type: MemoryType
    public let source: MemorySource
    public let metadata: [String: String]
    public let createdAt: Date
    public var lastAccessedAt: Date
    public var accessCount: Int
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        content: String,
        type: MemoryType,
        source: MemorySource = MemorySource(),
        metadata: [String: String] = [:],
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        accessCount: Int = 0,
        confidence: Double = 1.0
    ) {
        self.id = id
        self.content = content
        self.type = type
        self.source = source
        self.metadata = metadata
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.accessCount = accessCount
        self.confidence = confidence
    }
}

// MARK: - Memory JSON Coding

public extension JSONEncoder {
    static var memoryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var memoryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Memory Row View (shared across plugins)

public struct MemoryRowView: View {
    public let memory: MemoryEntry
    public let onDelete: () -> Void
    public let onSave: (String) -> Void
    @State private var isEditing = false
    @State private var editText = ""

    public init(memory: MemoryEntry, onDelete: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.memory = memory
        self.onDelete = onDelete
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveEdit() }
                HStack {
                    Button(String(localized: "Cancel")) { isEditing = false }
                        .buttonStyle(.borderless).font(.caption)
                    Button(String(localized: "Save")) { saveEdit() }
                        .buttonStyle(.borderless).font(.caption)
                }
            } else {
                Text(memory.content).font(.body)
            }

            HStack(spacing: 8) {
                Text(memory.type.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.secondary.opacity(0.15))
                    .clipShape(Capsule())
                if let app = memory.source.appName {
                    Text(app).font(.caption).foregroundStyle(.secondary)
                }
                Text(memory.createdAt, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { editText = memory.content; isEditing = true } label: {
                    Image(systemName: "pencil").font(.caption)
                }.buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func saveEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onSave(trimmed) }
        isEditing = false
    }
}

public struct MemoryQuery: Sendable {
    public let text: String
    public let types: [MemoryType]?
    public let maxResults: Int
    public let minConfidence: Double

    public init(text: String, types: [MemoryType]? = nil, maxResults: Int = 10, minConfidence: Double = 0.3) {
        self.text = text
        self.types = types
        self.maxResults = maxResults
        self.minConfidence = minConfidence
    }
}

public struct MemorySearchResult: Sendable {
    public let entry: MemoryEntry
    public let relevanceScore: Double

    public init(entry: MemoryEntry, relevanceScore: Double) {
        self.entry = entry
        self.relevanceScore = relevanceScore
    }
}

public protocol MemoryStoragePlugin: TypeWhisperPlugin {
    var storageName: String { get }
    var isReady: Bool { get }
    var memoryCount: Int { get }
    func store(_ entries: [MemoryEntry]) async throws
    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult]
    func delete(_ ids: [UUID]) async throws
    func update(_ entry: MemoryEntry) async throws
    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry]
    func deleteAll() async throws
}
