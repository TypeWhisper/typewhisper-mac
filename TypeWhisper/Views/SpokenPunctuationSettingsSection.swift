import SwiftUI

struct SpokenPunctuationSettingsSection: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var settings = SettingsViewModel.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var punctuationProfileStore = ServiceContainer.shared.dictationPunctuationProfileStore
    @State private var showPunctuationTestSheet = false

    private let punctuationStrategyResolver = ServiceContainer.shared.punctuationStrategyResolver
    private let punctuationVerificationService = ServiceContainer.shared.punctuationVerificationService

    var body: some View {
        Section("Spoken Punctuation") {
            if let context = activePunctuationContext,
               let resolved = resolvedPunctuationStrategy(for: context) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(context.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Strategy", selection: Binding(
                        get: { resolved.strategy },
                        set: { newValue in
                            savePunctuationStrategy(newValue, for: context, resolved: resolved)
                        }
                    )) {
                        ForEach(PunctuationStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }

                    Text(resolved.strategy.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(resolved.profile.verificationState.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Test Spoken Punctuation…") {
                        showPunctuationTestSheet = true
                    }
                    .buttonStyle(.bordered)
                }
            } else if settings.selectedLanguage == nil {
                Text("Set a spoken language to configure punctuation behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if modelManager.selectedProviderId == nil {
                Text("Select a transcription engine to configure punctuation behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No punctuation profile is available for the current selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPunctuationTestSheet) {
            if let context = activePunctuationContext,
               let resolved = resolvedPunctuationStrategy(for: context) {
                PunctuationVerificationSheet(
                    context: context,
                    scenarios: punctuationVerificationService.scenarios(for: context.languageCode)
                ) { strategy, verificationState in
                    savePunctuationStrategy(strategy, for: context, resolved: resolved, verificationState: verificationState, updateVerificationDate: true)
                }
            }
        }
    }

    private var activePunctuationContext: ActivePunctuationContext? {
        guard let engineId = modelManager.selectedProviderId,
              let engine = pluginManager.transcriptionEngine(for: engineId),
              let normalizedLanguage = PunctuationLanguageNormalizer.normalize(settings.selectedLanguage) else {
            return nil
        }

        let modelId = modelManager.selectedModelId(for: engineId)
        let modelName = engine.transcriptionModels.first(where: { $0.id == modelId })?.displayName
        let languageName = Locale.current.localizedString(forLanguageCode: normalizedLanguage) ?? normalizedLanguage

        return ActivePunctuationContext(
            engineId: engineId,
            engineName: engine.providerDisplayName,
            modelId: modelId,
            modelName: modelName,
            languageCode: normalizedLanguage,
            languageName: languageName
        )
    }

    private func resolvedPunctuationStrategy(for context: ActivePunctuationContext) -> ResolvedPunctuationStrategy? {
        let _ = punctuationProfileStore.profiles
        return punctuationStrategyResolver.resolve(
            engineId: context.engineId,
            modelId: context.modelId,
            configuredLanguage: context.languageCode,
            detectedLanguage: nil
        )
    }

    private func savePunctuationStrategy(
        _ strategy: PunctuationStrategy,
        for context: ActivePunctuationContext,
        resolved: ResolvedPunctuationStrategy,
        verificationState: PunctuationVerificationState? = nil,
        updateVerificationDate: Bool = false
    ) {
        punctuationProfileStore.saveUserOverride(
            engineId: context.engineId,
            modelId: context.modelId,
            languageCode: context.languageCode,
            defaultStrategy: resolved.profile.defaultStrategy,
            strategy: strategy,
            verificationState: verificationState ?? inferredVerificationState(for: strategy, fallback: resolved.profile.verificationState),
            updateVerificationDate: updateVerificationDate || strategy != .automatic
        )
    }

    private func inferredVerificationState(
        for strategy: PunctuationStrategy,
        fallback: PunctuationVerificationState
    ) -> PunctuationVerificationState {
        switch strategy {
        case .nativeOnly:
            return .userVerifiedGood
        case .fallbackOnly:
            return .userVerifiedBad
        case .automatic:
            return fallback
        }
    }
}

private struct ActivePunctuationContext: Identifiable {
    let engineId: String
    let engineName: String
    let modelId: String?
    let modelName: String?
    let languageCode: String
    let languageName: String

    var id: String {
        DictationPunctuationProfile.makeID(engineId: engineId, modelId: modelId, languageCode: languageCode)
    }

    var summary: String {
        if let modelName, !modelName.isEmpty {
            return "\(engineName) • \(modelName) • \(languageName)"
        }
        return "\(engineName) • \(languageName)"
    }
}

private struct PunctuationVerificationSheet: View {
    let context: ActivePunctuationContext
    let scenarios: [PunctuationVerificationScenario]
    let onDecision: (PunctuationStrategy, PunctuationVerificationState) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Test Spoken Punctuation")
                .font(.headline)

            Text("Use these phrases with \(context.summary) in any text field. If the native output already matches the expected result, keep Native. Otherwise use Fallback for this combination.")
                .foregroundStyle(.secondary)

            if scenarios.isEmpty {
                Text("No guided phrases are available for this language yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(scenarios, id: \.self) { scenario in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scenario.spoken)
                            .font(.body.monospaced())
                        Text("Expected: \(scenario.expected)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 220)
            }

            HStack {
                Button("Keep Automatic") {
                    dismiss()
                }
                Spacer()
                Button("Use Fallback") {
                    onDecision(.fallbackOnly, .userVerifiedBad)
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button("Native Works") {
                    onDecision(.nativeOnly, .userVerifiedGood)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
    }
}
