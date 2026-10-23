import SwiftUI
import TypeWhisperPluginSDK

struct SpeechPage: View {
    var body: some View {
        DictumPageFrame(page: .speech) {
            SpeechSettingsForm()
        }
    }
}

private struct SpeechSettingsForm: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject private var models = ServiceContainer.shared.modelManagerService
    @ObservedObject private var settings = SettingsViewModel.shared
    @StateObject private var network = SpeechNetworkStatus()
    @AppStorage(UserDefaultsKeys.indicatorTranscriptPreviewEnabled) private var previewEnabled = true
    @State private var expandedProvider: String?
    @State private var key = ""
    @State private var failure: String?
    @State private var moreLocal = false
    @State private var checkingKey = false
    @State private var checkedCredentials: [String: SpeechCredentialCheck.Result] = [:]

    private var engines: [any TranscriptionEnginePlugin] { plugins.transcriptionEngines }
    private var localEngines: [any TranscriptionEnginePlugin] {
        engines.filter { plugins.loadedTranscriptionPlugin(for: $0.providerId)?.manifest.resolvedLocality == .local }
    }
    private var cloudEngines: [any TranscriptionEnginePlugin] {
        engines.filter { plugins.loadedTranscriptionPlugin(for: $0.providerId)?.manifest.resolvedLocality != .local }
    }
    private var spokenLanguages: [String] {
        engines.first(where: { $0.providerId == models.selectedProviderId })?.supportedLanguages ?? []
    }
    private var languageLabel: String {
        let codes = settings.languageSelection.selectedCodes
        return codes.isEmpty ? String(localized: "Detect automatically", table: "DictumSpeech")
            : codes.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(spacing: 26) {
                    GroupedFormSection(title: "On this Mac", tableName: "DictumSpeech") {
                        if let qwen = engines.first(where: { $0.providerId == "qwen3" }) {
                            localRow(qwen, title: "Qwen3-ASR 1.7B")
                            GroupedFormRow(separated: true) {
                                Text("Precision", tableName: "DictumSpeech")
                                Spacer()
                                DictumPopup(title: "Precision", selection: Binding(get: { qwen.selectedModelId ?? SetupWizardQwen3Recommendation.preferredModelId(from: qwen.modelCatalog) ?? "" }, set: { qwen.selectModel($0) }), tableName: "DictumSpeech",
                                            value: Text(verbatim: qwen.modelCatalog.first { $0.id == qwen.selectedModelId }?.displayName ?? "")) {
                                    Text("8-bit · Faster", tableName: "DictumSpeech").tag("qwen3-asr-1.7b-8bit")
                                    Text("bf16 · More accurate", tableName: "DictumSpeech").tag("qwen3-asr-1.7b-bf16")
                                    if let selected = qwen.modelCatalog.first(where: { $0.id == qwen.selectedModelId }),
                                       !["qwen3-asr-1.7b-8bit", "qwen3-asr-1.7b-bf16"].contains(selected.id) {
                                        Text(verbatim: selected.displayName).tag(selected.id)
                                    }
                                }
                                .disabled(qwen.speechActivity != nil && qwen.speechActivity?.isError != true)
                            }.padding(.leading, 28)
                        }
                        if localEngines.contains(where: { $0.providerId != "qwen3" }) {
                            DisclosureGroup(isExpanded: $moreLocal) {
                                ForEach(localEngines.filter { $0.providerId != "qwen3" }, id: \.providerId) { engine in
                                    HStack {
                                        radio(engine) { models.selectProvider(engine.providerId) }
                                        Text(verbatim: engine.providerDisplayName)
                                        Spacer()
                                    }
                                    plugins.loadedTranscriptionPlugin(for: engine.providerId)?.instance.settingsView
                                }
                            } label: { Text("More local models", tableName: "DictumSpeech") }
                            .padding(.leading, 42).padding(.trailing, 14).padding(.vertical, 8)
                        }
                    }
                    GroupedFormSection(title: "Cloud", footer: "With cloud recognition, audio is sent to the provider you choose.", tableName: "DictumSpeech") {
                        ForEach(cloudEngines, id: \.providerId) { engine in cloudRow(engine) }
                    }
                    if !network.isOnline {
                        Text("You're offline. Cloud recognition is unavailable.", tableName: "DictumSpeech")
                            .font(.system(size: 12)).foregroundStyle(DictumTheme.warning)
                    }
                    if let failure { Text(verbatim: failure).foregroundStyle(DictumTheme.danger) }
                    GroupedFormSection(title: "Recognition", tableName: "DictumSpeech") {
                        GroupedFormRow {
                            Text("Spoken language", tableName: "DictumSpeech")
                            Spacer()
                            DictumPopup(title: "Spoken language", selection: $settings.languageSelection,
                                        tableName: "DictumSpeech", value: Text(verbatim: languageLabel)) {
                                Text("Detect automatically", tableName: "DictumSpeech").tag(LanguageSelection.auto)
                                ForEach(spokenLanguages, id: \.self) { code in
                                    Text(verbatim: Locale.current.localizedString(forLanguageCode: code) ?? code).tag(LanguageSelection.exact(code))
                                }
                                if !([LanguageSelection.auto] + spokenLanguages.map(LanguageSelection.exact)).contains(settings.languageSelection) {
                                    Text(verbatim: languageLabel).tag(settings.languageSelection)
                                }
                            }
                        }
                        GroupedFormToggle(title: "Show text while speaking", isOn: $previewEnabled, tableName: "DictumSpeech")
                    }
                }
                .frame(maxWidth: 620).padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .disabled(checkingKey)
            }
        }
    }

    private func radio(_ engine: any TranscriptionEnginePlugin, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: models.selectedProviderId == engine.providerId ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(models.selectedProviderId == engine.providerId ? DictumTheme.accent : DictumTheme.textTertiary)
        }.buttonStyle(.plain).accessibilityLabel(Text(verbatim: engine.providerDisplayName))
    }

    private func localRow(_ engine: any TranscriptionEnginePlugin, title: String) -> some View {
        GroupedFormRow {
            radio(engine) { models.selectProvider(engine.providerId) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: title).fontWeight(.medium)
                    if engine.providerId == "qwen3" { Badge(text: "Recommended", tint: DictumTheme.accent, tableName: "DictumSpeech") }
                }
                if engine.providerId == "qwen3" {
                    Text(verbatim: String(localized: "Accurate for mixed Chinese and English, works offline", table: "DictumSpeech")
                         + (engine.modelCatalog.first { $0.id == engine.selectedModelId }.map { " · " + $0.sizeDescription } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
                }
            }
            Spacer(minLength: 6)
            localStatus(engine)
        }.padding(.vertical, 7)
    }

    @ViewBuilder private func localStatus(_ engine: any TranscriptionEnginePlugin) -> some View {
        let activity = engine.speechActivity
        let model = engine.modelCatalog.first { $0.id == engine.selectedModelId }
        if let activity, !activity.isError {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: activity.progress).progressViewStyle(.linear)
                if let progress = activity.progress {
                    let details = SpeechDownloadProgress(engine: engine)
                    Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0))) + (details.map { " · " + $0.byteCounts } ?? ""))
                        .font(.system(size: 11)).lineLimit(1)
                    if let seconds = details?.remainingSeconds, seconds.isFinite {
                        Text(String(localized: "About \(max(1, Int(ceil(seconds / 60)))) min", table: "DictumSpeech"))
                            .font(.system(size: 11)).foregroundStyle(DictumTheme.textTertiary)
                    }
                } else { Text("Preparing model", tableName: "DictumSpeech").font(.system(size: 11)) }
            }.frame(width: 150)
            Button { invoke(engine, selector: "cancelModelDownload") } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel(Text("Cancel", tableName: "DictumSpeech"))
        } else if model?.downloaded == true {
            Text("Downloaded", tableName: "DictumSpeech").font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
            Menu {
                Button { reveal(engine) } label: { Text("Show in Finder", tableName: "DictumSpeech") }
                Button(role: .destructive) {
                    guard let id = engine.selectedModelId, let manager = engine as? any PluginDownloadedModelManaging else { return }
                    Task { do { try await manager.deleteDownloadedModel(id) } catch { failure = error.localizedDescription } }
                } label: { Text(String(localized: "Delete Model (\(model?.sizeDescription ?? ""))", table: "DictumSpeech")) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        } else {
            if let activity, activity.isError {
                Text(verbatim: activity.message).font(.system(size: 12)).lineLimit(2)
                    .foregroundStyle(DictumTheme.danger).help(activity.message)
            }
            Button { download(engine) } label: {
                Text(activity?.isError == true ? "Resume" : "Download", tableName: "DictumSpeech")
            }.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    private func cloudRow(_ engine: any TranscriptionEnginePlugin) -> some View {
        VStack(spacing: 0) {
            GroupedFormRow(separated: cloudEngines.first?.providerId != engine.providerId) {
                radio(engine) { selectCloud(engine) }
                Button { selectCloud(engine) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: engine.providerDisplayName).fontWeight(.medium)
                        if let model = engine.modelCatalog.first(where: { $0.id == engine.selectedModelId }) {
                            Text(verbatim: model.displayName).font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Badge(text: credentialLabel(engine), tint: checkedCredentials[engine.providerId] == .invalid ? DictumTheme.danger : (engine.isConfigured ? DictumTheme.success : nil), tableName: "DictumSpeech")
            }.padding(.vertical, 7)
            if expandedProvider == engine.providerId {
                if let plugin = plugins.loadedTranscriptionPlugin(for: engine.providerId), plugin.id == "com.typewhisper.openai-compatible" {
                    plugin.instance.settingsView.padding(14)
                } else {
                    HStack {
                        SecureField(text: $key) { Text(String(localized: "Paste \(engine.providerDisplayName) API key", table: "DictumSpeech")) }.textFieldStyle(.roundedBorder)
                        Button { saveKey(engine) } label: { Text("Test and Use", tableName: "DictumSpeech") }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 12)
                }
            }
        }.opacity(network.isOnline ? 1 : 0.45).disabled(!network.isOnline)
    }

    private func selectCloud(_ engine: any TranscriptionEnginePlugin) {
        key = ""
        expandedProvider = expandedProvider == engine.providerId ? nil : engine.providerId
        if engine.isConfigured { models.selectProvider(engine.providerId) }
    }

    private func saveKey(_ engine: any TranscriptionEnginePlugin) {
        guard let plugin = plugins.loadedTranscriptionPlugin(for: engine.providerId) else { return }
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingKey = true
        Task { @MainActor in
            defer { checkingKey = false }
            do {
                let result = try await SpeechCredentialCheck.check(pluginId: plugin.id, key: candidate,
                    sonioxRegion: UserDefaults.standard.string(forKey: "plugin.\(plugin.id).selectedRegion"),
                    deepgramBaseURL: UserDefaults.standard.string(forKey: "plugin.\(plugin.id).customBaseURL"),
                    deepgramAuthHeader: UserDefaults.standard.string(forKey: "plugin.\(plugin.id).customAuthHeader"))
                guard result == .connected else {
                    checkedCredentials[engine.providerId] = result
                    failure = result == .invalid ? String(localized: "Invalid key", table: "DictumSpeech")
                        : String(localized: "Could not connect. Try again.", table: "DictumSpeech")
                    return
                }
                try KeychainService.save(key: candidate, service: "\(plugin.id).api-key")
                if plugin.id == "com.typewhisper.openai" {
                    UserDefaults.standard.set("api-key", forKey: "plugin.\(plugin.id).authMode")
                }
                plugins.setPluginEnabled(plugin.id, enabled: true)
                models.selectProvider(engine.providerId)
                checkedCredentials[engine.providerId] = .connected
                key = ""
                expandedProvider = nil
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }

    private func credentialLabel(_ engine: any TranscriptionEnginePlugin) -> LocalizedStringKey {
        switch checkedCredentials[engine.providerId] {
        case .connected: "Connected"
        case .invalid: "Invalid key"
        default: engine.isConfigured ? "Configured" : "Not set up"
        }
    }

    private func download(_ engine: any TranscriptionEnginePlugin) {
        let id = engine.selectedModelId ?? (engine.providerId == "qwen3"
            ? SetupWizardQwen3Recommendation.preferredModelId(from: engine.modelCatalog) : engine.modelCatalog.first?.id)
        guard let id, let object = engine as? NSObject else { return }
        let selector = NSSelectorFromString("triggerRestoreModelForModel:")
        guard object.responds(to: selector) else { return }
        models.selectProvider(engine.providerId)
        object.perform(selector, with: id as NSString)
    }

    private func invoke(_ engine: any TranscriptionEnginePlugin, selector name: String) {
        guard let object = engine as? NSObject else { return }
        let selector = NSSelectorFromString(name)
        if object.responds(to: selector) { object.perform(selector) }
    }

    private func reveal(_ engine: any TranscriptionEnginePlugin) {
        guard let plugin = plugins.loadedTranscriptionPlugin(for: engine.providerId) else { return }
        NSWorkspace.shared.open(AppConstants.appSupportDirectory.appendingPathComponent("PluginData/\(plugin.id)/models"))
    }
}

private extension TranscriptionEnginePlugin {
    var speechActivity: PluginSettingsActivity? { (self as? any PluginSettingsActivityReporting)?.currentSettingsActivity }
}
