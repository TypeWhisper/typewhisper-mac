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

// MARK: - Post-Processor Plugin

public struct PostProcessingContext: Sendable {
    public let appName: String?
    public let bundleIdentifier: String?
    public let url: String?
    public let language: String?

    public init(appName: String? = nil, bundleIdentifier: String? = nil, url: String? = nil, language: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.language = language
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

public struct PluginTranscriptionResult: Sendable {
    public let text: String
    public let detectedLanguage: String?

    public init(text: String, detectedLanguage: String? = nil) {
        self.text = text
        self.detectedLanguage = detectedLanguage
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
