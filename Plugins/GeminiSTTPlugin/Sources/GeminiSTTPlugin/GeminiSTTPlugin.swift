import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

// MARK: - Plugin Entry Point

@objc(GeminiSTTPlugin)
final class GeminiSTTPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gemini-stt"
    static let pluginName = "Gemini STT"

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _systemPrompt: String?
    fileprivate var _glossary: String?
    fileprivate var _temperature: Double = 0.2

    private let logger = Logger(subsystem: "com.typewhisper.gemini-stt", category: "Plugin")
    private static let apiBase = "https://generativelanguage.googleapis.com/v1beta/models"

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.defaultModels.first?.id
        _systemPrompt = host.userDefault(forKey: "systemPrompt") as? String
        _glossary = host.userDefault(forKey: "glossary") as? String
        if let t = host.userDefault(forKey: "temperature") as? Double {
            _temperature = t
        }
    }

    func deactivate() {
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "gemini-stt" }
    var providerDisplayName: String { "Gemini STT" }

    var isConfigured: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    static let defaultModels: [PluginModelInfo] = [
        PluginModelInfo(id: "gemini-3.1-flash-lite-preview", displayName: "Gemini 3.1 Flash Lite (fastest, 100% accurate w/ glossary)"),
        PluginModelInfo(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash (higher quality)"),
        PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash (stable)"),
        PluginModelInfo(id: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash Lite (stable, cheapest)"),
    ]

    var transcriptionModels: [PluginModelInfo] { Self.defaultModels }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    // BCP-47 subset Gemini supports well for audio understanding
    var supportedLanguages: [String] {
        ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "tr",
         "ja", "ko", "zh", "ar", "hi", "id", "th", "vi", "sv", "da",
         "no", "fi", "cs", "el", "he", "hu", "ro", "uk"]
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate _: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let systemPrompt = renderSystemPrompt(perRulePromptTerms: prompt, language: language)
        let b64 = audio.wavData.base64EncodedString()

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": systemPrompt],
                    ["inlineData": ["mimeType": "audio/wav", "data": b64]],
                ],
            ]],
            "generationConfig": [
                "temperature": _temperature,
                "maxOutputTokens": 2048,
                "responseMimeType": "text/plain",
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]

        guard let url = URL(string: "\(Self.apiBase)/\(modelId):generateContent") else {
            throw PluginTranscriptionError.apiError("Invalid URL for model \(modelId)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            var message = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let m = err["message"] as? String {
                message = m
            }
            throw PluginTranscriptionError.apiError(message)
        }

        let text = try parseGeminiResponse(data)
        return PluginTranscriptionResult(text: text, detectedLanguage: language)
    }

    // MARK: - Prompt rendering

    static let defaultGlossary = """
    Qwen3, Qwen3-VL, Qwen3-ASR, Gemma, Llama, DeepSeek, Claude, GPT-5, o3, Sonnet, Opus, Haiku; LoRA, QLoRA, RLHF, DPO, GRPO, vLLM, SGLang, MLX, MLX-LM, llama.cpp, ONNX, TensorRT, Triton, PyTorch, JAX, HuggingFace, Transformers, TRL, Accelerate, bitsandbytes; Groq, OpenRouter, Anthropic, OpenAI, Together, Replicate, Fireworks, Modal, Runpod, Lambda Labs; Cloudflare Workers, SearXNG, Langfuse, LangSmith, LangChain, LlamaIndex, ClickHouse, Postgres, Supabase, Redis, Upstash, Neon, Turso; Next.js, SvelteKit, Astro, Remix, BetterAuth, Clerk, Auth.js, Resend, Nginx, Caddy, Traefik, Docker, Kubernetes; SSE, WebSocket, PKCE, OAuth, JWT, keepalive, proxy_read_timeout, proxy_buffering, X-Accel-Buffering; AVAudioEngine, AUInterfaceBase, AudioUnitPropertyListener, CoreAudio, Swift, ARC, dealloc, destructor, mutex, dispatch queue, teardown; M1 Max, M2, M3, M4, Apple Silicon, CUDA, ROCm, Metal
    """

    static let defaultSystemPrompt = """
    You are transcribing technical dictation from an ML/AI engineer. The speaker commonly uses these proper nouns (non-exhaustive):

    {GLOSSARY}

    Accurate spelling of model names, framework names, and technical terms is required. Additionally:
    - Preserve exact version numbers and numeric config values as spoken (e.g., "GPT-5.4", "Python 3.14", "keepalive 64"). Do NOT round toward familiar versions you know.
    - Preserve underscores, hyphens, and dots in identifiers and CLI flags exactly (e.g., proxy_read_timeout, --no-verify, X-Accel-Buffering, .tsx).
    - Collapse compound technical names without spaces (BetterAuth, ClickHouse, AVAudioEngine), and preserve CamelCase (useState, useEffect).
    - Numbers in technical contexts are digits, not words (write "404", not "four oh four").

    Use proper punctuation and casing. Output only the transcription, nothing else.
    """

    /// Merges plugin-level glossary with per-rule dictionary terms passed from the host.
    private func renderSystemPrompt(perRulePromptTerms: String?, language: String?) -> String {
        let template = (_systemPrompt?.isEmpty == false ? _systemPrompt : nil) ?? Self.defaultSystemPrompt
        let baseGlossary = (_glossary?.isEmpty == false ? _glossary : nil) ?? Self.defaultGlossary

        let baseTerms = PluginDictionaryTerms.terms(fromPrompt: baseGlossary)
        let ruleTerms = PluginDictionaryTerms.terms(fromPrompt: perRulePromptTerms)
        let merged = PluginDictionaryTerms.normalizedTerms(from: baseTerms + ruleTerms)
        let glossaryText = merged.joined(separator: ", ")

        var prompt = template.replacingOccurrences(of: "{GLOSSARY}", with: glossaryText)
        if let lang = language, !lang.isEmpty {
            prompt += "\n\nLanguage: \(lang)"
        }
        return prompt
    }

    private func parseGeminiResponse(_ data: Data) throws -> String {
        struct GeminiPart: Decodable { let text: String? }
        struct GeminiContent: Decodable { let parts: [GeminiPart]? }
        struct GeminiCandidate: Decodable {
            let content: GeminiContent?
            let finishReason: String?
        }
        struct GeminiResponse: Decodable { let candidates: [GeminiCandidate]? }

        do {
            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            guard let text = decoded.candidates?.first?.content?.parts?.compactMap(\.text).joined(),
                  !text.isEmpty else {
                throw PluginTranscriptionError.apiError("Empty response from Gemini")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as PluginTranscriptionError {
            throw e
        } catch {
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings hooks

    var settingsView: AnyView? {
        AnyView(GeminiSTTSettingsView(plugin: self))
    }

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do { try host.storeSecret(key: "api-key", value: key) }
            catch { logger.error("Failed to store API key: \(error.localizedDescription, privacy: .public)") }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do { try host.storeSecret(key: "api-key", value: "") }
            catch { logger.error("Failed to delete API key: \(error.localizedDescription, privacy: .public)") }
            host.notifyCapabilitiesChanged()
        }
    }

    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func setSystemPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        _systemPrompt = trimmed.isEmpty ? nil : trimmed
        host?.setUserDefault(_systemPrompt, forKey: "systemPrompt")
    }

    func setGlossary(_ glossary: String) {
        let trimmed = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        _glossary = trimmed.isEmpty ? nil : trimmed
        host?.setUserDefault(_glossary, forKey: "glossary")
    }

    func setTemperature(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        _temperature = clamped
        host?.setUserDefault(clamped, forKey: "temperature")
    }

    var currentTemperature: Double { _temperature }
}

// MARK: - Settings View

private struct GeminiSTTSettingsView: View {
    let plugin: GeminiSTTPlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var systemPromptText: String = ""
    @State private var glossaryText: String = ""
    @State private var temperature: Double = 0.2
    @State private var showAdvanced = false
    private let bundle = Bundle(for: GeminiSTTPlugin.self)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                apiKeySection
                if plugin.isConfigured {
                    Divider()
                    modelSection
                    Divider()
                    systemPromptSection
                    Divider()
                    glossarySection
                    Divider()
                    advancedSection
                }

                Text("API keys are stored securely in the Keychain. Audio is sent directly to Google AI Studio (no third-party proxy).", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: loadStateFromPlugin)
    }

    // MARK: Sections

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Google AI Studio API Key", bundle: bundle)
                .font(.headline)

            HStack(spacing: 8) {
                if showApiKey {
                    TextField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                }
                Button { showApiKey.toggle() } label: {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                if plugin.isConfigured {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        apiKeyInput = ""
                        validationResult = nil
                        plugin.removeApiKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                } else {
                    Button(String(localized: "Save", bundle: bundle)) { saveApiKey() }
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
                    Text(result
                         ? String(localized: "Valid API Key", bundle: bundle)
                         : String(localized: "Invalid API Key", bundle: bundle))
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }

            Text("Get a free key at aistudio.google.com/apikey", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model", bundle: bundle)
                .font(.headline)

            Picker("Model", selection: $selectedModel) {
                ForEach(plugin.transcriptionModels, id: \.id) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .onChange(of: selectedModel) { plugin.selectModel(selectedModel) }
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System Prompt", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button(String(localized: "Reset to Default", bundle: bundle)) {
                    systemPromptText = GeminiSTTPlugin.defaultSystemPrompt
                    plugin.setSystemPrompt(systemPromptText)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Instructions for Gemini. Use `{GLOSSARY}` as a placeholder — it gets replaced with your glossary terms at request time.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $systemPromptText)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: systemPromptText) { plugin.setSystemPrompt(systemPromptText) }
        }
    }

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Glossary", bundle: bundle)
                    .font(.headline)
                Spacer()
                Button(String(localized: "Reset to Default", bundle: bundle)) {
                    glossaryText = GeminiSTTPlugin.defaultGlossary
                    plugin.setGlossary(glossaryText)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Technical terms, comma-separated. These are substituted into `{GLOSSARY}` in the system prompt. Add terms you use that Gemini might mishear (model names, frameworks, internal tools).", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $glossaryText)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: glossaryText) { plugin.setGlossary(glossaryText) }
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature", bundle: bundle)
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", temperature))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
                        .onChange(of: temperature) { plugin.setTemperature(temperature) }
                    Text("0 = deterministic. 0.2 is the validated sweet spot for transcription; higher values add creativity you probably don't want.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced", bundle: bundle)
                .font(.headline)
        }
    }

    // MARK: Actions

    private func loadStateFromPlugin() {
        if let key = plugin._apiKey, !key.isEmpty { apiKeyInput = key }
        selectedModel = plugin.selectedModelId
            ?? plugin.transcriptionModels.first?.id
            ?? ""
        systemPromptText = plugin._systemPrompt ?? GeminiSTTPlugin.defaultSystemPrompt
        glossaryText = plugin._glossary ?? GeminiSTTPlugin.defaultGlossary
        temperature = plugin.currentTemperature
    }

    private func saveApiKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        plugin.setApiKey(trimmed)
        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmed)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
            }
        }
    }
}
