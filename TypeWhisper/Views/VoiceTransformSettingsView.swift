import SwiftUI

struct VoiceTransformSettingsView: View {
    @State private var showPrompts = false
    @AppStorage(UserDefaultsKeys.transformStartCompact) private var startCompact = true
    @AppStorage(UserDefaultsKeys.transformRememberReviewSize) private var rememberReviewSize = true
    @AppStorage(UserDefaultsKeys.transformInstructionLimit) private var instructionLimit = 2_000
    @AppStorage(UserDefaultsKeys.transformSourceLimit) private var sourceLimit = 12_000
    @AppStorage(UserDefaultsKeys.transformResultLimit) private var resultLimit = 24_000
    @AppStorage(UserDefaultsKeys.transformRecordingLimit) private var recordingLimit = 60

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader("Transform")
            Picker("Transform settings", selection: $showPrompts) {
                Text("General").tag(false)
                Text("Prompts").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, 12)
            Divider()

            if showPrompts {
                Text("Spoken triggers such as ‘my rewrite’ expand into editing instructions. Prompts scoped to Both are shared with dictation; edits also appear in Snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SettingsLayoutMetrics.pagePadding)
                SnippetsSettingsView(transformOnly: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                        GroupBox("Voice Transform") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Select text in another app, speak a change, then review and replace or copy the result.")
                                    .foregroundStyle(.secondary)
                                MultiHotkeySlotRecorder(
                                    slot: .voiceTransform,
                                    title: "Transform shortcut",
                                    subtitle: "Press to record an instruction; press again to review."
                                )
                                Text("Your dictation shortcuts continue to dictate, even when text is selected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        windowSettings
                        limitsSettings
                        GroupBox("Shared settings") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Transform uses the global LLM fallback order, models, and effort configured in Workflows. Changes there also apply to inherited workflows.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Open Workflows → Global LLM Fallbacks") {
                                    SettingsNavigationCoordinator.shared.navigate(to: .workflows)
                                }
                                Divider()
                                Text("Microphone, transcription, and access permissions are shared with Dictation.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Open Dictation settings") {
                                    SettingsNavigationCoordinator.shared.navigate(to: .dictation)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(SettingsLayoutMetrics.pagePadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowSettings: some View {
        GroupBox("Window") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Start compact while recording", isOn: $startCompact)
                Toggle("Remember review window size", isOn: $rememberReviewSize)
                Text("Drag the review window’s edges to choose its size. Recording and error windows do not overwrite the saved review size. With compact mode off, recording uses the review size too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset window size") { VoiceTransformWindowPreferences.resetSize() }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var limitsSettings: some View {
        GroupBox("Limits") {
            VStack(alignment: .leading, spacing: 12) {
                limitRow("Instruction characters", value: $instructionLimit, range: VoiceTransformLimits.instructionRange, step: 100)
                limitRow("Selected-text characters", value: $sourceLimit, range: VoiceTransformLimits.sourceRange, step: 1_000)
                limitRow("Result characters", value: $resultLimit, range: VoiceTransformLimits.resultRange, step: 1_000)
                limitRow("Recording seconds", value: $recordingLimit, range: VoiceTransformLimits.recordingRange, step: 10)
                Text("Instruction limits include expanded prompts. Text over a limit is rejected, never truncated. Result length is an acceptance limit, not a requested rewrite length. Providers may impose lower limits. Recording stops automatically at its time limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Changes apply to the next recording or Retry. An active recording or request keeps its starting limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset limits") {
                    instructionLimit = 2_000
                    sourceLimit = 12_000
                    resultLimit = 24_000
                    recordingLimit = 60
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func limitRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        TransformLimitRow(title: title, value: value, range: range, step: step)
    }
}

private struct TransformLimitRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var boundedValue: Binding<Int> {
        Binding(
            get: { VoiceTransformLimits.clamp(value, to: range) },
            set: { value = VoiceTransformLimits.clamp($0, to: range) }
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text("\(range.lowerBound.formatted())–\(range.upperBound.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField(title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .focused($isEditing)
                .onSubmit { commit() }
                .onChange(of: isEditing) { _, editing in
                    if !editing { commit() }
                }
            Stepper(title, value: boundedValue, in: range, step: step)
                .labelsHidden()
        }
        .onAppear { draft = String(boundedValue.wrappedValue) }
        .onChange(of: value) { _, _ in draft = String(boundedValue.wrappedValue) }
    }

    private func commit() {
        if let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)) {
            boundedValue.wrappedValue = number
        }
        draft = String(boundedValue.wrappedValue)
    }
}

struct VoiceTransformSnippetScopePicker: View {
    @ObservedObject var viewModel: SnippetsViewModel

    var body: some View {
        Picker("Use in", selection: $viewModel.editScope) {
            ForEach(SnippetScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        if viewModel.editScope.includesVoiceTransform {
            Text("Voice prompts match whole phrases without case sensitivity. Clipboard placeholders are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
