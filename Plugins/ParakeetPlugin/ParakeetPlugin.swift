import Foundation
import SwiftUI
import FluidAudio
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ParakeetPlugin)
final class ParakeetPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.parakeet"
    static let pluginName = "Parakeet"

    fileprivate var host: HostServices?
    fileprivate var asrManager: AsrManager?
    fileprivate var loadedModelId: String?
    fileprivate var modelState: ParakeetModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        Task { await restoreLoadedModel() }
    }

    func deactivate() {
        asrManager = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "parakeet" }
    var providerDisplayName: String { "Parakeet" }

    var isConfigured: Bool {
        asrManager != nil && loadedModelId != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        guard loadedModelId != nil else { return [] }
        return [PluginModelInfo(
            id: Self.modelDef.id,
            displayName: Self.modelDef.displayName,
            sizeDescription: Self.modelDef.sizeDescription,
            languageCount: 25
        )]
    }

    var selectedModelId: String? { loadedModelId }

    func selectModel(_ modelId: String) {
        // Only one model, no-op
    }

    var supportsTranslation: Bool { false }

    var supportedLanguages: [String] {
        ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let asrManager else {
            throw PluginTranscriptionError.notConfigured
        }

        if translate {
            throw PluginTranscriptionError.apiError("Parakeet does not support translation")
        }

        let result = try await asrManager.transcribe(audio.samples, source: .system)

        return PluginTranscriptionResult(text: result.text, detectedLanguage: nil)
    }

    // MARK: - Model Management

    fileprivate func loadModel() async {
        modelState = .downloading
        downloadProgress = 0.1

        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            downloadProgress = 0.7

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            downloadProgress = 1.0

            asrManager = manager
            loadedModelId = Self.modelDef.id
            modelState = .ready

            host?.setUserDefault(Self.modelDef.id, forKey: "loadedModel")
            host?.notifyCapabilitiesChanged()
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    fileprivate func unloadModel() {
        asrManager = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        host?.setUserDefault(nil, forKey: "loadedModel")
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func restoreLoadedModel() async {
        guard host?.userDefault(forKey: "loadedModel") as? String != nil else {
            return
        }
        await loadModel()
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(ParakeetSettingsView(plugin: self))
    }

    // MARK: - Model Definition

    static let modelDef = ParakeetModelDef(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet TDT v3",
        sizeDescription: "~600 MB",
        ramRequirement: "8 GB+"
    )
}

// MARK: - Model Types

struct ParakeetModelDef {
    let id: String
    let displayName: String
    let sizeDescription: String
    let ramRequirement: String
}

enum ParakeetModelState: Equatable {
    case notLoaded
    case downloading
    case ready
    case error(String)
}

// MARK: - Settings View

private struct ParakeetSettingsView: View {
    let plugin: ParakeetPlugin
    @State private var modelState: ParakeetModelState = .notLoaded
    @State private var downloadProgress: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Parakeet")
                .font(.headline)

            Text("NVIDIA Parakeet TDT - extremely fast on Apple Silicon. 25 European languages, no API key required.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ParakeetPlugin.modelDef.displayName)
                        .font(.body)
                    Text("\(ParakeetPlugin.modelDef.sizeDescription) - RAM: \(ParakeetPlugin.modelDef.ramRequirement)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                switch modelState {
                case .notLoaded:
                    Button("Download & Load") {
                        Task {
                            await plugin.loadModel()
                            modelState = plugin.modelState
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                    }

                case .ready:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Unload") {
                            plugin.unloadModel()
                            modelState = plugin.modelState
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                case .error(let message):
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Button("Retry") {
                            Task {
                                await plugin.loadModel()
                                modelState = plugin.modelState
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
            downloadProgress = plugin.downloadProgress
        }
    }
}
