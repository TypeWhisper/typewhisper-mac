import Foundation
import SwiftUI
import TypeWhisperPluginSDK
import os

enum SupertonicDefaultsKey {
    static let selectedVoiceId = "selectedVoiceId"
    static let speed = "speed"
    static let quality = "quality"
    static let hfToken = "hf-token"
    static let acceptedModelLicenseId = "acceptedModelLicenseId"
    static let acceptedModelLicenseRevision = "acceptedModelLicenseRevision"
    static let acceptedModelLicenseAt = "acceptedModelLicenseAt"
}

enum SupertonicQuality: String, CaseIterable, Sendable {
    case fast
    case balanced
    case high

    var totalSteps: Int {
        switch self {
        case .fast: 2
        case .balanced: 5
        case .high: 10
        }
    }

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .high: "High"
        }
    }
}

enum SupertonicModelState: Equatable, Sendable {
    case notDownloaded
    case downloading
    case ready
    case error(String)
}

struct SupertonicSynthesisOutput: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

protocol SupertonicSynthesizing: AnyObject, Sendable {
    func synthesize(
        text: String,
        language: String,
        voiceId: String,
        quality: SupertonicQuality,
        speed: Double
    ) throws -> SupertonicSynthesisOutput
}

@objc(SupertonicPlugin)
final class SupertonicPlugin: NSObject, TTSProviderPlugin, PluginSettingsActivityReporting, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tts.supertonic"
    static let pluginName = "Supertonic (Experimental)"
    private static let downloadedModelId = "supertonic-3"

    private let logger = Logger(subsystem: "com.typewhisper.tts.supertonic", category: "Plugin")
    private var host: HostServices?
    private let synthesizerLock = NSLock()
    private var synthesizer: (any SupertonicSynthesizing)?
    private var downloadProgress = 0.0
    private(set) var modelState: SupertonicModelState = .notDownloaded

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        modelState = modelAssetManager.hasDownloadedModel() ? .ready : .notDownloaded
    }

    func deactivate() {
        clearSynthesizerCache()
        host = nil
        downloadProgress = 0
        modelState = .notDownloaded
    }

    var providerId: String { "supertonic" }
    var providerDisplayName: String { "Supertonic (Experimental)" }
    var isConfigured: Bool { modelAssetManager.hasDownloadedModel() }
    var availableVoices: [PluginVoiceInfo] { modelAssetManager.availableVoices() }

    var selectedVoiceId: String? {
        (host?.userDefault(forKey: SupertonicDefaultsKey.selectedVoiceId) as? String) ?? "M1"
    }

    var selectedSpeed: Double {
        let raw = host?.userDefault(forKey: SupertonicDefaultsKey.speed) as? Double ?? 1.05
        return Self.clampedSpeed(raw)
    }

    var selectedQuality: SupertonicQuality {
        if let raw = host?.userDefault(forKey: SupertonicDefaultsKey.quality) as? String,
           let quality = SupertonicQuality(rawValue: raw) {
            return quality
        }
        return .balanced
    }

    var settingsSummary: String? {
        let voice = selectedVoiceId ?? "M1"
        return "Voice: \(voice) - Speed: \(String(format: "%.2fx", selectedSpeed)) - \(selectedQuality.displayName)"
    }

    var downloadedModels: [PluginModelInfo] {
        guard modelAssetManager.hasDownloadedModel() else { return [] }
        return [
            PluginModelInfo(
                id: Self.downloadedModelId,
                displayName: "Supertonic 3",
                sizeDescription: "Local TTS assets",
                downloaded: true,
                loaded: modelState == .ready
            )
        ]
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard modelId == Self.downloadedModelId else { return }
        try deleteCachedModel()
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(SupertonicSettingsView(plugin: self))
    }

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notDownloaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(message: "Downloading Supertonic model", progress: downloadProgress)
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var hasAcceptedCurrentModelLicense: Bool {
        guard let host else { return false }
        return host.userDefault(forKey: SupertonicDefaultsKey.acceptedModelLicenseId) as? String == SupertonicModelLicense.id
            && host.userDefault(forKey: SupertonicDefaultsKey.acceptedModelLicenseRevision) as? String == SupertonicModelLicense.revision
    }

    var canDownloadModel: Bool {
        hasAcceptedCurrentModelLicense
    }

    var huggingFaceToken: String? {
        PluginHuggingFaceTokenHelper.loadToken(from: host)
    }

    var modelDownloadProgress: Double {
        downloadProgress
    }

    func selectVoice(_ voiceId: String?) {
        host?.setUserDefault(voiceId, forKey: SupertonicDefaultsKey.selectedVoiceId)
    }

    func setSpeed(_ speed: Double) {
        host?.setUserDefault(Self.clampedSpeed(speed), forKey: SupertonicDefaultsKey.speed)
    }

    func setQuality(_ quality: SupertonicQuality) {
        host?.setUserDefault(quality.rawValue, forKey: SupertonicDefaultsKey.quality)
    }

    func acceptCurrentModelLicense(now: Date = Date()) {
        host?.setUserDefault(SupertonicModelLicense.id, forKey: SupertonicDefaultsKey.acceptedModelLicenseId)
        host?.setUserDefault(SupertonicModelLicense.revision, forKey: SupertonicDefaultsKey.acceptedModelLicenseRevision)
        host?.setUserDefault(Self.isoDateString(from: now), forKey: SupertonicDefaultsKey.acceptedModelLicenseAt)
        host?.notifyCapabilitiesChanged()
    }

    func saveHuggingFaceToken(_ token: String) {
        PluginHuggingFaceTokenHelper.saveToken(token, to: host)
    }

    func clearHuggingFaceToken() {
        PluginHuggingFaceTokenHelper.clearToken(from: host)
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(token, dataFetcher: dataFetcher)
    }

    func downloadModel() async {
        guard canDownloadModel else {
            modelState = .error(SupertonicPluginError.licenseNotAccepted.localizedDescription)
            host?.notifyCapabilitiesChanged()
            return
        }

        downloadProgress = 0
        modelState = .downloading
        host?.notifyCapabilitiesChanged()

        do {
            try await modelAssetManager.download(token: huggingFaceToken, licenseAccepted: true) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.host?.notifyCapabilitiesChanged()
                }
            }
            clearSynthesizerCache()
            downloadProgress = 1
            modelState = .ready
            host?.notifyCapabilitiesChanged()
        } catch {
            logger.error("Supertonic model download failed: \(error.localizedDescription)")
            downloadProgress = 0
            modelState = .error(error.localizedDescription)
            host?.notifyCapabilitiesChanged()
        }
    }

    func deleteCachedModel() throws {
        clearSynthesizerCache()
        try modelAssetManager.deleteModelFiles()
        downloadProgress = 0
        modelState = .notDownloaded
        host?.notifyCapabilitiesChanged()
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SupertonicPluginError.emptyText }
        guard modelAssetManager.hasDownloadedModel() else {
            throw SupertonicPluginError.notConfigured
        }

        let voiceId = selectedVoiceId ?? "M1"
        let language = SupertonicLanguageResolver.normalizedLanguageCode(for: request.language)
        let quality = selectedQuality
        let speed = selectedSpeed

        let output = try await Task.detached(priority: .userInitiated) { [self] in
            try synthesizerForCurrentModel().synthesize(
                text: text,
                language: language,
                voiceId: voiceId,
                quality: quality,
                speed: speed
            )
        }.value

        return try SupertonicPlaybackSession(samples: output.samples, sampleRate: output.sampleRate)
    }

    fileprivate var modelAssetManager: SupertonicModelAssetManager {
        SupertonicModelAssetManager(
            rootDirectory: host?.pluginDataDirectory
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("SupertonicPlugin", isDirectory: true)
        )
    }

    private func synthesizerForCurrentModel() throws -> any SupertonicSynthesizing {
        synthesizerLock.lock()
        defer { synthesizerLock.unlock() }

        if let synthesizer {
            return synthesizer
        }
        let synthesizer = try SupertonicONNXSynthesizer(modelDirectory: modelAssetManager.modelDirectory)
        self.synthesizer = synthesizer
        return synthesizer
    }

    private func clearSynthesizerCache() {
        synthesizerLock.lock()
        synthesizer = nil
        synthesizerLock.unlock()
    }

    private static func clampedSpeed(_ value: Double) -> Double {
        min(max(value, 0.7), 2.0)
    }

    private static func isoDateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct SupertonicSettingsView: View {
    let plugin: SupertonicPlugin

    @State private var acceptedLicense = false
    @State private var selectedVoiceId = "M1"
    @State private var speed = 1.05
    @State private var quality: SupertonicQuality = .balanced
    @State private var modelState: SupertonicModelState = .notDownloaded
    @State private var progress = 0.0
    @State private var hfTokenInput = ""
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var isDownloading = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Supertonic (Experimental)")
                .font(.headline)

            Text("Local text-to-speech powered by Supertonic 3 ONNX models. Model assets are downloaded only after you accept the model license.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            licenseSection

            Divider()

            modelSection

            Divider()

            voiceSection

            Divider()

            tokenSection
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            refreshFromPlugin()
        }
        .onReceive(pollTimer) { _ in
            refreshTransientState()
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model License")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Supertonic 3 model assets are licensed under OpenRAIL-M and include use restrictions. Review the full license before downloading the model.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link("Open Supertonic 3 OpenRAIL-M license", destination: SupertonicModelLicense.url)
                .font(.caption)

            Toggle(isOn: $acceptedLicense) {
                Text("I have read and accept the Supertonic 3 model license terms")
            }
            .onChange(of: acceptedLicense) { _, newValue in
                if newValue {
                    plugin.acceptCurrentModelLicense()
                }
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model")
                .font(.subheadline)
                .fontWeight(.medium)

            switch modelState {
            case .ready:
                HStack {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Delete cached model") {
                        try? plugin.deleteCachedModel()
                        refreshFromPlugin()
                    }
                    .controlSize(.small)
                }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 160)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                downloadButton
            case .notDownloaded:
                downloadButton
            }
        }
    }

    private var downloadButton: some View {
        Button {
            isDownloading = true
            Task {
                await plugin.downloadModel()
                await MainActor.run {
                    isDownloading = false
                    refreshFromPlugin()
                }
            }
        } label: {
            Label("Download & Load", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!acceptedLicense || isDownloading || modelState == .downloading)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Voice", selection: $selectedVoiceId) {
                ForEach(plugin.availableVoices, id: \.id) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .onChange(of: selectedVoiceId) { _, newValue in
                plugin.selectVoice(newValue)
            }

            HStack {
                Text("Speed")
                Spacer()
                Text(speed, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Slider(value: $speed, in: 0.7...2.0, step: 0.05)
                .onChange(of: speed) { _, newValue in
                    plugin.setSpeed(newValue)
                }

            Picker("Quality", selection: $quality) {
                ForEach(SupertonicQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .onChange(of: quality) { _, newValue in
                plugin.setQuality(newValue)
            }
        }
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hugging Face Token")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Optional. It can increase download rate limits for the model download.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("hf_...", text: $hfTokenInput)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    validateAndSaveHuggingFaceToken()
                }
                .controlSize(.small)
                .disabled(hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingToken)

                if plugin.huggingFaceToken != nil {
                    Button("Remove") {
                        hfTokenInput = ""
                        tokenValidationResult = nil
                        plugin.clearHuggingFaceToken()
                    }
                    .controlSize(.small)
                }
            }

            if isValidatingToken {
                ProgressView()
                    .controlSize(.small)
            } else if let tokenValidationResult {
                Label(
                    tokenValidationResult ? "Valid Hugging Face token" : "Invalid Hugging Face token",
                    systemImage: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(tokenValidationResult ? .green : .red)
            }
        }
    }

    private func validateAndSaveHuggingFaceToken() {
        let trimmed = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isValidatingToken = true
        tokenValidationResult = nil
        Task {
            let isValid = await plugin.validateHuggingFaceToken(trimmed)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    plugin.saveHuggingFaceToken(trimmed)
                }
            }
        }
    }

    private func refreshFromPlugin() {
        acceptedLicense = plugin.hasAcceptedCurrentModelLicense
        selectedVoiceId = plugin.selectedVoiceId ?? "M1"
        speed = plugin.selectedSpeed
        quality = plugin.selectedQuality
        modelState = plugin.modelState
        progress = plugin.modelDownloadProgress
        hfTokenInput = plugin.huggingFaceToken ?? ""
    }

    private func refreshTransientState() {
        modelState = plugin.modelState
        progress = plugin.modelDownloadProgress
    }
}
