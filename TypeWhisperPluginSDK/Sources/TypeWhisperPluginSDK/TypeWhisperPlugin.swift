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
    /// Whether the model's weights are available locally (nil when the plugin does not report this).
    public let downloaded: Bool?
    /// Whether the model is currently loaded into memory (nil when the plugin does not report this).
    public let loaded: Bool?

    public init(
        id: String,
        displayName: String,
        sizeDescription: String = "",
        languageCount: Int = 0,
        downloaded: Bool? = nil,
        loaded: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.languageCount = languageCount
        self.downloaded = downloaded
        self.loaded = loaded
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
    public let ruleName: String?
    public let selectedText: String?

    public init(appName: String? = nil, bundleIdentifier: String? = nil, url: String? = nil, language: String? = nil, ruleName: String? = nil, selectedText: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.language = language
        self.ruleName = ruleName
        self.selectedText = selectedText
    }

    @available(*, deprecated, renamed: "init(appName:bundleIdentifier:url:language:ruleName:selectedText:)")
    public init(appName: String? = nil, bundleIdentifier: String? = nil, url: String? = nil, language: String? = nil, profileName: String?, selectedText: String? = nil) {
        self.init(appName: appName, bundleIdentifier: bundleIdentifier, url: url, language: language, ruleName: profileName, selectedText: selectedText)
    }

    @available(*, deprecated, renamed: "ruleName")
    public var profileName: String? { ruleName }
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

public enum PluginAudioUtils {
    public static func paddedSamples(
        _ samples: [Float],
        minimumDuration: TimeInterval,
        sampleRate: Int = 16_000
    ) -> [Float] {
        let minimumSampleCount = Int(minimumDuration * Double(sampleRate))
        guard samples.count < minimumSampleCount else { return samples }

        var paddedSamples = samples
        paddedSamples.append(contentsOf: repeatElement(Float.zero, count: minimumSampleCount - samples.count))
        return paddedSamples
    }

    public static func shouldAcceptShortClipTranscription(
        audioDuration: TimeInterval,
        confidence: Float,
        minimumDuration: TimeInterval = 1.0,
        minimumConfidence: Float = 0.55
    ) -> Bool {
        guard audioDuration < minimumDuration else { return true }
        return confidence >= minimumConfidence
    }
}

// Backward-compatibility shim for older plugins that referenced `AudioUtils`.
@available(*, deprecated, message: "Use PluginAudioUtils instead")
public enum AudioUtils {
    public static func paddedSamples(
        _ samples: [Float],
        minimumDuration: TimeInterval,
        sampleRate: Int = 16_000
    ) -> [Float] {
        PluginAudioUtils.paddedSamples(
            samples,
            minimumDuration: minimumDuration,
            sampleRate: sampleRate
        )
    }

    public static func shouldAcceptShortClipTranscription(
        audioDuration: TimeInterval,
        confidence: Float,
        minimumDuration: TimeInterval = 1.0,
        minimumConfidence: Float = 0.55
    ) -> Bool {
        PluginAudioUtils.shouldAcceptShortClipTranscription(
            audioDuration: audioDuration,
            confidence: confidence,
            minimumDuration: minimumDuration,
            minimumConfidence: minimumConfidence
        )
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

public struct PluginLanguageSelection: Sendable, Equatable {
    public let requestedLanguage: String?
    public let languageHints: [String]

    public init(requestedLanguage: String? = nil, languageHints: [String] = []) {
        self.requestedLanguage = requestedLanguage
        self.languageHints = languageHints
    }
}

public enum DictionaryTermsSupport: String, Sendable, CaseIterable {
    case supported
    case requiresPluginSetting
    case unsupported
}

public protocol DictionaryTermsCapabilityProviding: TypeWhisperPlugin {
    var dictionaryTermsSupport: DictionaryTermsSupport { get }
}

public protocol LiveTranscriptionSession: AnyObject, Sendable {
    func appendAudio(samples: [Float]) async throws
    func finish() async throws -> PluginTranscriptionResult
    func cancel() async
}

public enum PluginDictionaryTerms {
    public static func normalizedTerms(from terms: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for rawTerm in terms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }

            let dedupeKey = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(dedupeKey).inserted else { continue }
            normalized.append(term)
        }

        return normalized
    }

    public static func terms(fromPrompt prompt: String?) -> [String] {
        guard let prompt, !prompt.isEmpty else { return [] }
        return normalizedTerms(from: prompt.split(separator: ",").map(String.init))
    }

    public static func prompt(from terms: [String], maxLength: Int = 600) -> String? {
        let normalized = normalizedTerms(from: terms)
        guard !normalized.isEmpty else { return nil }

        var result = ""
        for (index, term) in normalized.enumerated() {
            let separator = index > 0 ? ", " : ""
            guard result.count + separator.count + term.count <= maxLength else { break }
            result += separator + term
        }

        return result.isEmpty ? nil : result
    }

    public static func contextBiasTokens(fromPrompt prompt: String?) -> [String] {
        let tokens = terms(fromPrompt: prompt).flatMap { term in
            term.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        }
        return normalizedTerms(from: tokens)
    }
}

public protocol TranscriptionEnginePlugin: TypeWhisperPlugin {
    var providerId: String { get }
    var providerDisplayName: String { get }
    var isConfigured: Bool { get }
    var transcriptionModels: [PluginModelInfo] { get }
    /// Full catalogue this engine can select from, including variants not currently
    /// downloaded or loaded. Default implementation returns `transcriptionModels`, so
    /// existing plugins keep their current behaviour. Plugins that hide un-loaded
    /// variants from `transcriptionModels` (to keep the GUI model picker quiet) should
    /// override this to surface the full catalogue to API consumers like /v1/models.
    var availableModels: [PluginModelInfo] { get }
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
    var availableModels: [PluginModelInfo] { transcriptionModels }
}

public protocol LiveTranscriptionCapablePlugin: TranscriptionEnginePlugin {
    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession
}

public protocol LanguageHintTranscriptionEnginePlugin: TranscriptionEnginePlugin {
    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult

    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult
}

public protocol LiveLanguageHintTranscriptionCapablePlugin: LiveTranscriptionCapablePlugin {
    func createLiveTranscriptionSession(
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession
}

public extension LanguageHintTranscriptionEnginePlugin {
    func transcribe(
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            languageSelection: languageSelection,
            translate: translate,
            prompt: prompt
        )
    }
}

public extension TranscriptionEnginePlugin {
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] { [] }
    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?,
                    onProgress: @Sendable @escaping (String) -> Bool) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
    }
}

// MARK: - Text-to-Speech Provider Plugin

public enum TTSPurpose: String, Sendable, Codable, CaseIterable {
    case status
    case transcription
    case manualReadback
}

public struct TTSSpeakRequest: Sendable, Equatable {
    public let text: String
    public let language: String?
    public let purpose: TTSPurpose

    public init(text: String, language: String? = nil, purpose: TTSPurpose) {
        self.text = text
        self.language = language
        self.purpose = purpose
    }
}

public struct PluginVoiceInfo: Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let localeIdentifier: String?

    public init(id: String, displayName: String, localeIdentifier: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
    }
}

public protocol TTSPlaybackSession: AnyObject, Sendable {
    var isActive: Bool { get }
    var onFinish: (@Sendable () -> Void)? { get set }
    func stop()
}

public protocol TTSProviderPlugin: TypeWhisperPlugin {
    var providerId: String { get }
    var providerDisplayName: String { get }
    var isConfigured: Bool { get }
    var availableVoices: [PluginVoiceInfo] { get }
    var selectedVoiceId: String? { get }
    var settingsSummary: String? { get }
    func selectVoice(_ voiceId: String?)
    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession
}

public extension TTSProviderPlugin {
    var settingsSummary: String? { nil }
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
    public let ruleName: String?
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case appName
        case bundleIdentifier
        case ruleName
        case profileName
        case timestamp
    }

    public init(appName: String? = nil, bundleIdentifier: String? = nil,
                ruleName: String? = nil, timestamp: Date = Date()) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.ruleName = ruleName
        self.timestamp = timestamp
    }

    @available(*, deprecated, renamed: "init(appName:bundleIdentifier:ruleName:timestamp:)")
    public init(appName: String? = nil, bundleIdentifier: String? = nil,
                profileName: String?, timestamp: Date = Date()) {
        self.init(appName: appName, bundleIdentifier: bundleIdentifier, ruleName: profileName, timestamp: timestamp)
    }

    @available(*, deprecated, renamed: "ruleName")
    public var profileName: String? { ruleName }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        ruleName = try container.decodeIfPresent(String.self, forKey: .ruleName)
            ?? container.decodeIfPresent(String.self, forKey: .profileName)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(ruleName, forKey: .ruleName)
        try container.encodeIfPresent(ruleName, forKey: .profileName)
        try container.encode(timestamp, forKey: .timestamp)
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
