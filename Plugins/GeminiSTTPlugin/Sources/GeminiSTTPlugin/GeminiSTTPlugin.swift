import AVFoundation
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
        // Shadow-cache the API key in UserDefaults so activate() doesn't hit the keychain
        // on every plugin reload. Without this, every rebuild produces a new ad-hoc cdhash,
        // which invalidates the keychain ACL and triggers a macOS "wants to access key …"
        // prompt on each TypeWhisper restart.
        //
        // SECURITY TRADEOFF: ~/Library/Preferences/<bundle>.plist is user-UID-readable; any
        // process running as the same user can `defaults read` it silently — strictly weaker
        // than login.keychain. No at-rest encryption. The plist can end up in Time Machine
        // and iCloud Desktop & Documents backups. The key is still written to the keychain
        // as the source of truth; this is a dev/UX convenience only.
        //
        // CLEAN FIX (shipped builds): sign the plugin with the same Developer ID as the
        // host + add `keychain-access-groups` entitlement. Then teamid:-partitioned ACLs
        // match across rebuilds regardless of cdhash, and this shadow cache can be removed.
        // See tests/research notes (2026-04-19) for the full analysis.
        if let cached = host.userDefault(forKey: "apiKeyCache") as? String, !cached.isEmpty {
            _apiKey = cached
        } else {
            _apiKey = host.loadSecret(key: "api-key")
            if let key = _apiKey, !key.isEmpty {
                host.setUserDefault(key, forKey: "apiKeyCache")
            }
        }
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
            ?? Self.defaultModels.first?.id
        _systemPrompt = host.userDefault(forKey: "systemPrompt") as? String
        _glossary = host.userDefault(forKey: "glossary") as? String
        if let t = host.userDefault(forKey: "temperature") as? Double {
            _temperature = t
        }
        warmUpConnection()
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
    // Streaming disabled: measured slower on every clip (Gemini batches SSE emission for
    // transcription; TTFT ≈ total_http). See tests/gemini_phase3.jsonl.
    var supportsStreaming: Bool { false }
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
        try await performTranscription(
            audio: audio,
            language: language,
            prompt: prompt,
            onProgress: { _ in true }
        )
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate _: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await performTranscription(
            audio: audio,
            language: language,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    // MARK: - Shared streaming transcription (Phase 3)
    //
    // Always uses `streamGenerateContent?alt=sse`. Non-streaming callers pass a no-op
    // onProgress and simply receive the final accumulated text. Streaming callers see
    // incremental text as Gemini emits SSE frames, which the host displays live via
    // DictationViewModel.partialText / PartialTranscriptionUpdate events.

    private func performTranscription(
        audio: AudioData,
        language: String?,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard let modelId = _selectedModelId else {
            throw PluginTranscriptionError.noModelSelected
        }

        let systemPrompt = renderSystemPrompt(perRulePromptTerms: prompt, language: language)

        // Compress audio to FLAC (lossless, ~50% of WAV). On encode failure fall back to
        // WAV rather than failing the transcription — FLAC is a best-effort speed win.
        let tEncodeStart = CFAbsoluteTimeGetCurrent()
        let encodedAudio: Data
        let mimeType: String
        do {
            encodedAudio = try encodeFlac(samples: audio.samples)
            mimeType = "audio/flac"
        } catch {
            logger.error("FLAC encode failed, using WAV: \(error.localizedDescription, privacy: .public)")
            encodedAudio = audio.wavData
            mimeType = "audio/wav"
        }
        let tEncodeEnd = CFAbsoluteTimeGetCurrent()

        let tB64Start = CFAbsoluteTimeGetCurrent()
        let b64 = encodedAudio.base64EncodedString()
        let tB64End = CFAbsoluteTimeGetCurrent()

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": systemPrompt],
                    ["inlineData": ["mimeType": mimeType, "data": b64]],
                ],
            ]],
            "generationConfig": [
                "temperature": _temperature,
                "maxOutputTokens": 2048,
                "responseMimeType": "text/plain",
                "thinkingConfig": Self.thinkingConfig(for: modelId),
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

        let tBodyStart = CFAbsoluteTimeGetCurrent()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let tBodyEnd = CFAbsoluteTimeGetCurrent()

        let tHTTPStart = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await Self.httpSession.data(for: request)
        let tHTTPEnd = CFAbsoluteTimeGetCurrent()

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

        let tParseStart = CFAbsoluteTimeGetCurrent()
        let text = try parseGeminiResponse(data)
        let tParseEnd = CFAbsoluteTimeGetCurrent()

        // onProgress gets called once with the full text so the host's streaming handler
        // still receives the final value. This is a no-op for non-streaming callers.
        _ = onProgress(text)

        recordTimings(
            model: modelId,
            codec: mimeType,
            audioDurationS: audio.duration,
            wavBytes: audio.wavData.count,
            encodedBytes: encodedAudio.count,
            payloadBytes: b64.utf8.count,
            encodeMs: (tEncodeEnd - tEncodeStart) * 1000,
            b64Ms: (tB64End - tB64Start) * 1000,
            bodyMs: (tBodyEnd - tBodyStart) * 1000,
            httpMs: (tHTTPEnd - tHTTPStart) * 1000,
            parseMs: (tParseEnd - tParseStart) * 1000,
            ttftMs: 0,
            chunks: 0,
            status: httpResponse.statusCode,
            resultChars: text.count
        )

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

    // MARK: - Audio compression (Phase 2 — FLAC)
    //
    // FLAC is lossless and natively supported by both AVAudioFile (`kAudioFormatFLAC`)
    // and Gemini (`audio/flac`). Expected: ~50% of WAV size on 16 kHz mono voice, zero
    // WER impact. Encoding overhead: tens of ms per 60 s of audio on Apple Silicon.

    private func encodeFlac(samples: [Float], sampleRate: Int = 16000) throws -> Data {
        guard !samples.isEmpty else { return Data() }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-stt-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Write in a nested scope so AVAudioFile releases (and flushes its last page)
        // before we read the bytes back.
        try Self.writeFlacFile(samples: samples, sampleRate: sampleRate, url: tempURL)
        return try Data(contentsOf: tempURL)
    }

    private static func writeFlacFile(samples: [Float], sampleRate: Int, url: URL) throws {
        // Use Int16 throughout. If we pass Float32 buffers to AVAudioFile with a 16-bit
        // FLAC setting, the encoder still writes 32-bit-depth FLAC (~no compression vs
        // the float-wav baseline). Quantizing to Int16 in Swift gives us true 16-bit
        // FLAC and ~50% compression on voice.
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw PluginTranscriptionError.apiError("Invalid PCM format for FLAC encode")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let chunkSize = 4096
        var index = 0
        while index < samples.count {
            let frames = min(chunkSize, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channel = buffer.int16ChannelData?[0] else {
                throw PluginTranscriptionError.apiError("FLAC buffer alloc failed")
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames {
                let clamped = max(-1.0, min(1.0, samples[index + i]))
                channel[i] = Int16(clamped * 32767.0)
            }
            try file.write(from: buffer)
            index += frames
        }
        // `file` goes out of scope here → AVAudioFile deinit flushes the FLAC stream to disk.
    }

    // MARK: - Gemini config helpers (Phase 1)

    /// Gemini 3.x silently ignores `thinkingBudget: 0`; the documented minimum-thinking
    /// flag for 3.x models is `thinkingLevel: "minimal"`. Gemini 2.5 keeps the older
    /// `thinkingBudget: 0` contract. This helper picks the right one per model.
    static func thinkingConfig(for modelId: String) -> [String: Any] {
        if modelId.hasPrefix("gemini-3") {
            return ["thinkingLevel": "minimal"]
        }
        return ["thinkingBudget": 0]
    }

    // MARK: - Long-lived URLSession + connection warm-up (Phase 1)
    //
    // The SDK's PluginHTTPClient creates a fresh ephemeral session per call to dodge
    // a known macOS stale-connection bug after sleep/wake. That defeats TLS/H2/H3
    // connection reuse — every transcription pays a full handshake to Google's edge.
    // We trade that freshness for speed with a default session that reuses connections
    // within the keepalive window (~6 min). Tight timeouts cap the blast radius of a
    // genuinely stale connection to one slow call.

    private static let httpSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private func warmUpConnection() {
        guard let url = URL(string: Self.apiBase) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        Task.detached(priority: .userInitiated) {
            _ = try? await Self.httpSession.data(for: request)
        }
    }

    // MARK: - Timing instrumentation (Phase 0)
    //
    // Emits two artifacts per transcription:
    //   1. A structured [GEMINI_TIMING] line via os.Logger — tail with:
    //        log stream --predicate 'subsystem BEGINSWITH "com.typewhisper.gemini-stt"' | grep GEMINI_TIMING
    //   2. A JSONL record at ~/Library/Application Support/TypeWhisper/PluginData/GeminiSTT/timings.jsonl
    //      — analyze with jq, e.g.:
    //        jq -s 'map(.steps_ms.http) | add/length' timings.jsonl

    private static let timingsFileURL: URL? = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("TypeWhisper", isDirectory: true)
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent("GeminiSTT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timings.jsonl")
    }()

    private static let timingsISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    fileprivate func recordTimings(
        model: String,
        codec: String,
        audioDurationS: Double,
        wavBytes: Int,
        encodedBytes: Int,
        payloadBytes: Int,
        encodeMs: Double,
        b64Ms: Double,
        bodyMs: Double,
        httpMs: Double,
        parseMs: Double,
        ttftMs: Double,
        chunks: Int,
        status: Int,
        resultChars: Int
    ) {
        let totalMs = encodeMs + b64Ms + bodyMs + httpMs + parseMs
        let record: [String: Any] = [
            "ts": Self.timingsISOFormatter.string(from: Date()),
            "model": model,
            "codec": codec,
            "audio_dur_s": audioDurationS,
            "wav_bytes": wavBytes,
            "encoded_bytes": encodedBytes,
            "payload_bytes": payloadBytes,
            "steps_ms": [
                "encode": encodeMs,
                "b64_encode": b64Ms,
                "body_serialize": bodyMs,
                "http": httpMs,
                "parse": parseMs,
            ],
            "ttft_ms": ttftMs,
            "stream_chunks": chunks,
            "total_plugin_ms": totalMs,
            "http_status": status,
            "result_chars": resultChars,
        ]

        logger.info("""
        [GEMINI_TIMING] model=\(model, privacy: .public) \
        codec=\(codec, privacy: .public) \
        dur=\(audioDurationS, format: .fixed(precision: 2), privacy: .public)s \
        wav=\(wavBytes, privacy: .public)B \
        enc=\(encodedBytes, privacy: .public)B \
        payload=\(payloadBytes, privacy: .public)B \
        encode_ms=\(encodeMs, format: .fixed(precision: 1), privacy: .public) \
        b64_ms=\(b64Ms, format: .fixed(precision: 1), privacy: .public) \
        body_ms=\(bodyMs, format: .fixed(precision: 1), privacy: .public) \
        http_ms=\(httpMs, format: .fixed(precision: 1), privacy: .public) \
        parse_ms=\(parseMs, format: .fixed(precision: 1), privacy: .public) \
        ttft_ms=\(ttftMs, format: .fixed(precision: 1), privacy: .public) \
        chunks=\(chunks, privacy: .public) \
        total_ms=\(totalMs, format: .fixed(precision: 1), privacy: .public) \
        chars=\(resultChars, privacy: .public)
        """)

        guard let url = Self.timingsFileURL,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }

        var line = data
        line.append(0x0a) // newline

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
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
            host.setUserDefault(key, forKey: "apiKeyCache")
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do { try host.storeSecret(key: "api-key", value: "") }
            catch { logger.error("Failed to delete API key: \(error.localizedDescription, privacy: .public)") }
            host.setUserDefault("", forKey: "apiKeyCache")
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
