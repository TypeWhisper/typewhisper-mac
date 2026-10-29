import AppKit
import SwiftUI
import TypeWhisperPluginSDK

/// Two visible steps: run the recording again with other settings, then compare the
/// new result with the text in use and apply it explicitly. Technical notes stay collapsed.
struct HistoryRetranscriptionView: View {
    let record: TranscriptionRecord
    @ObservedObject var service: HistoryRetranscriptionService
    @Environment(\.dismiss) private var dismiss
    @State private var engineID = ""
    @State private var modelID: String?
    @State private var language: String?
    @State private var workflowID: UUID?
    @State private var selectedVersionID: UUID?
    @State private var plan: HistoryRetranscriptionService.Plan?
    @State private var planError: String?
    @State private var cloudConfirmed = false
    @State private var downloadConfirmed = false
    @State private var showPromotionConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var showDetails = false
    @State private var cancelRequested = false

    private var container: ServiceContainer { .shared }
    private var engines: [any TranscriptionEnginePlugin] { PluginManager.shared?.transcriptionEngines ?? [] }
    private var engine: (any TranscriptionEnginePlugin)? { engines.first { $0.providerId == engineID } }
    private var models: [PluginModelInfo] { engine.map { HistoryRetranscriptionEnvironment.models(for: $0) } ?? [] }
    private var versions: [HistoryTranscriptionVersion] { (try? record.savedTranscriptionVersions()) ?? [] }
    private var activeVersion: HistoryTranscriptionVersion {
        versions.first { $0.isActive(in: record) } ?? .capture(record)
    }
    /// Everything that is not the text in use; the newest run is listed last.
    private var candidates: [HistoryTranscriptionVersion] { versions.filter { !$0.isActive(in: record) } }
    private var selectedVersion: HistoryTranscriptionVersion? { candidates.first { $0.id == selectedVersionID } }
    private var running: Bool { service.runningRecordID != nil }
    private var request: HistoryRetranscriptionService.Request {
        .init(engineID: engineID, modelID: modelID, language: language, workflowID: workflowID,
              appBundleIdentifier: record.appBundleIdentifier, appURL: record.appURL)
    }
    private var canStart: Bool {
        plan != nil && service.canRun(record)
            && (plan?.requiresCloudConfirmation != true || cloudConfirmed)
            && (service.hasLocalAudio(record) || downloadConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "history.retranscribe.title")).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(String(localized: "history.retranscribe.subtitle"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runSection
                    compareSection
                    DisclosureGroup(isExpanded: $showDetails) {
                        Text(String(localized: "history.retranscribe.localVersions"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    } label: {
                        Text(String(localized: "history.retranscribe.details")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(running)
            }
        }
        .padding(22)
        .frame(width: 860, height: 720)
        .interactiveDismissDisabled(running)
        .confirmationDialog(String(localized: "history.retranscribe.promoteTitle"), isPresented: $showPromotionConfirmation) {
            Button(String(localized: "history.retranscribe.promote")) {
                promoteSelectedVersion()
            }
        } message: { Text(String(localized: "history.retranscribe.promoteMessage")) }
        .confirmationDialog(String(localized: "history.retranscribe.discardTitle"), isPresented: $showDiscardConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                discardSelectedVersion()
            }
        }
        .onAppear {
            engineID = container.modelManagerService.selectedProviderId ?? engines.first?.providerId ?? ""
            modelID = engine?.selectedModelId
            language = HistoryRetranscriptionEnvironment.supportedLanguage(record.language, modelID: modelID, engine: engine)
            selectedVersionID = candidates.last?.id
            refreshPlan()
        }
        .onChange(of: engineID) { previousID, _ in
            // onAppear already initialized the model and the recording's language.
            guard !previousID.isEmpty else { return }
            modelID = engine?.selectedModelId
            language = nil
            refreshPlan()
        }
        .onChange(of: modelID) { _, _ in
            language = HistoryRetranscriptionEnvironment.supportedLanguage(language, modelID: modelID, engine: engine)
            refreshPlan()
        }
        .onChange(of: language) { _, _ in refreshPlan() }
        .onChange(of: workflowID) { _, _ in refreshPlan() }
        .onChange(of: record.transcriptionVersionsData) { _, _ in selectedVersionID = candidates.last?.id }
        .onChange(of: record.activeTranscriptionVersionID) { _, _ in selectedVersionID = candidates.last?.id }
        .onChange(of: service.runningRecordID) { previousID, currentID in
            guard previousID == record.id, currentID == nil else { return }
            announceRunFinished()
        }
        .onChange(of: displayedError) { _, message in
            guard let message else { return }
            container.accessibilityAnnouncementService.announceError(message)
        }
        .onDisappear { service.cancel() }
    }

    private var displayedError: String? { service.errorMessage ?? planError }

    private var statusText: String {
        service.isCancelling ? String(localized: "history.retranscribe.cancelling")
            : String(localized: "history.retranscribe.running")
    }

    // MARK: VoiceOver announcements

    /// The run, and choosing or deleting a result, only change the sheet's
    /// content, so VoiceOver users hear the outcome. Errors are announced by
    /// the error label's own change.
    private func announceRunFinished() {
        defer { cancelRequested = false }
        guard service.errorMessage == nil else { return }
        if cancelRequested {
            announce(String(localized: "Cancelled"))
        } else {
            announce(localizedAppText(
                "New result ready to compare",
                de: "Neues Ergebnis zum Vergleichen bereit",
                ja: "比較できる新しい結果があります",
                zh: "新结果已可供比较",
                zhHant: "新結果已可供比較"
            ))
        }
    }

    private func promoteSelectedVersion() {
        guard let selectedVersionID else { return }
        service.promote(selectedVersionID, in: record)
        guard service.errorMessage == nil else { return }
        announce(localizedAppText(
            "This result is now the text of the entry",
            de: "Dieses Ergebnis ist jetzt der Text des Eintrags",
            ja: "この結果がエントリのテキストになりました",
            zh: "此结果现已成为该条目的文本",
            zhHant: "此結果現已成為該條目的文字"
        ))
    }

    private func discardSelectedVersion() {
        if let selectedVersionID {
            service.discard(selectedVersionID, in: record)
            if service.errorMessage == nil {
                announce(localizedAppText("Version deleted", de: "Version gelöscht", ja: "バージョンを削除しました", zh: "版本已删除", zhHant: "版本已刪除"))
            }
        }
        selectedVersionID = candidates.last?.id
    }

    private func announce(_ message: String) {
        container.accessibilityAnnouncementService.announce(message)
    }

    // MARK: Step 1

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel(1, String(localized: "history.retranscribe.step1"))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    configuration.disabled(running)
                    if !service.canRun(record) {
                        Label(String(localized: "history.retranscribe.audioMissing"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if !service.hasLocalAudio(record) {
                        Toggle(String(localized: "history.retranscribe.downloadConsent"), isOn: $downloadConfirmed)
                            .disabled(running)
                    }
                    if let plan, plan.requiresCloudConfirmation {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                String(format: String(localized: "history.retranscribe.cloudNotice"),
                                       plan.cloudProviders.joined(separator: ", ")),
                                systemImage: "icloud.and.arrow.up"
                            )
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            Toggle(String(localized: "history.retranscribe.cloudConsent"), isOn: $cloudConfirmed)
                                .disabled(running)
                        }
                    }
                    if let message = displayedError {
                        Label(message, systemImage: "xmark.octagon")
                            .foregroundStyle(.red).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        if running {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(statusText)
                            Text(statusText)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Button(String(localized: "Cancel")) {
                                cancelRequested = true
                                service.cancel()
                            }
                            .disabled(service.isCancelling)
                        } else {
                            Button {
                                cancelRequested = false
                                service.start(record: record, request: request, cloudConfirmed: cloudConfirmed,
                                              downloadConfirmed: downloadConfirmed, confirmedPlan: plan)
                            } label: {
                                Label(String(localized: "history.retranscribe.run"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canStart)
                            .accessibilityIdentifier("history.retranscribe.run")
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var configuration: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Picker(String(localized: "Engine"), selection: $engineID) {
                    ForEach(engines, id: \.providerId) { engine in
                        Text(engine.providerDisplayName).tag(engine.providerId)
                    }
                }
                Picker(String(localized: "Model"), selection: $modelID) {
                    if models.isEmpty { Text(String(localized: "Default")).tag(nil as String?) }
                    ForEach(models, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                }
            }
            GridRow {
                Picker(String(localized: "Language"), selection: $language) {
                    Text(String(localized: "history.retranscribe.autoLanguage")).tag(nil as String?)
                    ForEach(engine?.supportedLanguages(forModel: modelID).sorted() ?? [], id: \.self) { code in
                        Text(localizedAppLanguageName(for: code)).tag(Optional(code))
                    }
                }
                Picker(String(localized: "Workflow"), selection: $workflowID) {
                    Text(String(localized: "history.retranscribe.noWorkflow")).tag(nil as UUID?)
                    ForEach(container.workflowService.workflows.filter(\.isEnabled)) { workflow in
                        Text(workflow.name).tag(Optional(workflow.id))
                    }
                }
            }
        }
    }

    // MARK: Step 2

    private var compareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel(2, String(localized: "history.retranscribe.step2"))
            HStack(alignment: .top, spacing: 14) {
                currentPanel
                resultPanel
            }
        }
    }

    private var currentPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                versionBody(activeVersion)
                Button(String(localized: "history.retranscribe.copyText")) { copy(activeVersion.finalText) }
                    .controlSize(.small)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Text(String(localized: "history.retranscribe.current"))
                Label(String(localized: "history.retranscribe.inUse"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var resultPanel: some View {
        GroupBox {
            Group {
                if running {
                    placeholder(String(localized: "history.retranscribe.runningResult"), progress: true)
                } else if let version = selectedVersion {
                    VStack(alignment: .leading, spacing: 10) {
                        if candidates.count > 1 {
                            Picker(String(localized: "history.retranscribe.version"), selection: $selectedVersionID) {
                                ForEach(candidates) { candidate in
                                    Text(versionTitle(candidate)).tag(Optional(candidate.id))
                                }
                            }
                        }
                        versionBody(version)
                        if version.finalText == activeVersion.finalText {
                            Label(String(localized: "history.retranscribe.sameText"), systemImage: "equal.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack(spacing: 10) {
                            Button(String(localized: "history.retranscribe.promote")) { showPromotionConfirmation = true }
                                .buttonStyle(.borderedProminent)
                                .fixedSize()
                                .accessibilityIdentifier("history.retranscribe.promote")
                            Button(String(localized: "history.retranscribe.copyText")) { copy(version.finalText) }
                                .fixedSize()
                            Spacer()
                            if version.canDiscard(in: record) {
                                Button(role: .destructive) {
                                    showDiscardConfirmation = true
                                } label: {
                                    Label(String(localized: "history.retranscribe.discard"), systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .help(String(localized: "history.retranscribe.discard"))
                                .accessibilityIdentifier("history.retranscribe.discard")
                            }
                        }
                    }
                } else {
                    placeholder(String(localized: "history.retranscribe.noVersions"), progress: false)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(selectedVersion?.id == record.id
                 ? String(localized: "Original") : String(localized: "history.retranscribe.alternative"))
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ message: String, progress: Bool) -> some View {
        VStack(spacing: 10) {
            if progress {
                ProgressView().controlSize(.regular)
                    .accessibilityLabel(message)
            } else {
                Image(systemName: "text.badge.plus").font(.largeTitle).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.horizontal, 12)
    }

    private func versionBody(_ version: HistoryTranscriptionVersion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provenance(version)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(provenanceParts(version).joined(separator: ", "))
            Text(version.finalText).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if version.rawText != version.finalText {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(version.rawText).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "history.retranscribe.copyRaw")) { copy(version.rawText) }
                            .controlSize(.small)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(String(localized: "history.retranscribe.rawText")).font(.caption)
                }
            }
        }
    }

    private func stepLabel(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(title).font(.headline)
        }
        // "Step 1 of 2, …" as one heading instead of a lone number.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String.localizedStringWithFormat(String(localized: "Step %lld of %lld"), Int64(number), Int64(2))
                + ", " + title
        )
        .accessibilityAddTraits(.isHeader)
    }

    private func engineName(_ version: HistoryTranscriptionVersion) -> String {
        version.engineName ?? engines.first { $0.providerId == version.engineID }?.providerDisplayName ?? version.engineID
    }

    private func versionTitle(_ version: HistoryTranscriptionVersion) -> String {
        let name = version.id == record.id ? String(localized: "Original") : engineName(version)
        return "\(name) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func provenance(_ version: HistoryTranscriptionVersion) -> String {
        provenanceParts(version).joined(separator: " · ")
    }

    private func provenanceParts(_ version: HistoryTranscriptionVersion) -> [String] {
        var parts: [String] = [engineName(version)]
        if let model = version.modelName ?? version.modelID { parts.append(model) }
        if let language = version.language { parts.append(localizedAppLanguageName(for: language)) }
        if version.workflowRecorded {
            parts.append(version.workflowName ?? String(localized: "history.retranscribe.noWorkflow"))
        }
        parts.append(version.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts
    }

    private func refreshPlan() {
        cloudConfirmed = false
        do { plan = try service.previewPlan(request); planError = nil }
        catch { plan = nil; planError = error.localizedDescription }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
