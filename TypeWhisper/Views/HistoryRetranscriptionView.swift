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
    @State private var highlights: Highlights?
    @AppStorage(UserDefaultsKeys.historyComparisonHighlightsDifferences) private var highlightsDifferences = true

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
        .task(id: comparisonKey) { await refreshHighlights(for: comparisonKey) }
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
                zh: "新结果已可供比较"
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
            zh: "此结果现已成为该条目的文本"
        ))
    }

    private func discardSelectedVersion() {
        if let selectedVersionID {
            service.discard(selectedVersionID, in: record)
            if service.errorMessage == nil {
                announce(localizedAppText("Version deleted", de: "Version gelöscht", ja: "バージョンを削除しました", zh: "版本已删除"))
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
            HStack(alignment: .firstTextBaseline) {
                stepLabel(2, String(localized: "history.retranscribe.step2"))
                Spacer()
                if !candidates.isEmpty {
                    Toggle(String(localized: "history.retranscribe.highlightDifferences"), isOn: $highlightsDifferences)
                        .toggleStyle(.checkbox)
                        .help(String(localized: "history.retranscribe.highlightHelp"))
                        .accessibilityHint(String(localized: "history.retranscribe.highlightHelp"))
                        .accessibilityIdentifier("history.retranscribe.highlightDifferences")
                }
            }
            HStack(alignment: .top, spacing: 14) {
                currentPanel
                resultPanel
            }
        }
    }

    private var currentPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                versionBody(activeVersion, marks: shownHighlights?.comparison.currentRanges ?? [], style: .removed)
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
                        versionBody(version, marks: shownHighlights?.comparison.otherRanges ?? [], style: .added)
                        differenceSummary(version)
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

    private func versionBody(
        _ version: HistoryTranscriptionVersion, marks: [Range<String.Index>], style: HistoryComparisonTextView.MarkStyle
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provenance(version)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(provenanceParts(version).joined(separator: ", "))
            timing(version)
            HistoryComparisonTextView(text: version.finalText, marks: marks, style: style)
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

    // MARK: Processing time

    @ViewBuilder
    private func timing(_ version: HistoryTranscriptionVersion) -> some View {
        let parts = timingParts(version, spoken: false)
        if !parts.isEmpty {
            Label {
                Text(parts.joined(separator: " · "))
            } icon: {
                Image(systemName: "stopwatch")
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .help(String(localized: "history.retranscribe.timingHelp"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(timingParts(version, spoken: true).joined(separator: ", "))
            .accessibilityHint(String(localized: "history.retranscribe.timingHelp"))
        }
    }

    /// Only measured values: versions without a measurement show no time at all.
    private func timingParts(_ version: HistoryTranscriptionVersion, spoken: Bool) -> [String] {
        var parts: [String] = []
        if let seconds = version.engineSeconds, seconds.isFinite, seconds > 0 {
            parts.append(String(format: String(localized: "history.retranscribe.engineTime"),
                                Self.formattedSeconds(seconds, spoken: spoken)))
            let audioSeconds = record.durationSeconds
            if audioSeconds.isFinite, audioSeconds > 0 {
                let factor = audioSeconds / seconds
                let shown = factor.formatted(.number.precision(.fractionLength(factor < 10 ? 0...1 : 0...0)))
                parts.append(String(format: String(localized: "history.retranscribe.realTimeFactor"), shown))
            }
        }
        if let seconds = version.workflowSeconds, seconds.isFinite, seconds >= 0 {
            parts.append(String(format: String(localized: "history.retranscribe.workflowTime"),
                                Self.formattedSeconds(seconds, spoken: spoken)))
        }
        return parts
    }

    /// "2.4s" or "3m 5s"; VoiceOver hears "2.4 seconds". Below 0.1 s shows 0.1 s, not 0.
    private static func formattedSeconds(_ seconds: Double, spoken: Bool) -> String {
        let shown = max(seconds, 0.1)
        return Duration.milliseconds(Int64((shown * 1_000).rounded())).formatted(.units(
            allowed: [.hours, .minutes, .seconds], width: spoken ? .wide : .narrow, maximumUnitCount: 2,
            fractionalPart: shown < 10 ? .show(length: 1) : .hide
        ))
    }

    // MARK: Differences

    private struct ComparisonKey: Equatable {
        let current: String
        let other: String
    }

    private struct Highlights {
        let key: ComparisonKey
        let comparison: HistoryTextComparison
    }

    /// The pair the result panel shows, or nil while a run replaces it or marking is off.
    private var comparisonKey: ComparisonKey? {
        guard highlightsDifferences, !running, let selectedVersion else { return nil }
        let current = activeVersion.finalText
        guard selectedVersion.finalText != current else { return nil }
        return ComparisonKey(current: current, other: selectedVersion.finalText)
    }

    /// Highlights computed for another pair are never shown: their ranges belong to other text.
    private var shownHighlights: Highlights? {
        guard let highlights, let key = comparisonKey, highlights.key == key else { return nil }
        return highlights
    }

    /// Long recordings are compared off the main thread; the panels show plain text until then.
    private func refreshHighlights(for key: ComparisonKey?) async {
        guard let key else {
            highlights = nil
            return
        }
        if highlights?.key == key { return }
        let comparison = await Task.detached(priority: .userInitiated) {
            HistoryTextComparison(current: key.current, other: key.other)
        }.value
        guard !Task.isCancelled else { return }
        highlights = Highlights(key: key, comparison: comparison)
    }

    /// The visible count is also what VoiceOver reads; the marking itself is not announced.
    @ViewBuilder
    private func differenceSummary(_ version: HistoryTranscriptionVersion) -> some View {
        if version.finalText == activeVersion.finalText {
            Label(String(localized: "history.retranscribe.sameText"), systemImage: "equal.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if let highlights = shownHighlights {
            Group {
                switch highlights.comparison.outcome {
                case .changed(let count):
                    Label(String.localizedStringWithFormat(String(localized: "history.retranscribe.differences"), Int64(count)),
                          systemImage: "highlighter")
                case .whitespaceOnly:
                    Label(String(localized: "history.retranscribe.whitespaceOnly"), systemImage: "equal.circle")
                case .tooManyChanges:
                    Label(String(localized: "history.retranscribe.tooManyChanges"), systemImage: "exclamationmark.circle")
                case .identical:
                    EmptyView()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("history.retranscribe.differenceSummary")
        }
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

/// A version's text, selectable and read-only, with the differences marked. SwiftUI's
/// selectable `Text` copies rich text, which would paste the marks into other apps; this view
/// writes only plain text when the selection is copied, dragged or sent to a service.
struct HistoryComparisonTextView: NSViewRepresentable {
    enum MarkStyle {
        /// Removed or replaced in the other version: light red and struck through.
        case removed
        /// New in this version: yellow and underlined.
        case added
    }

    let text: String
    let marks: [Range<String.Index>]
    let style: MarkStyle

    func makeNSView(context: Context) -> HistoryPlainCopyTextView {
        HistoryPlainCopyTextView()
    }

    func updateNSView(_ view: HistoryPlainCopyTextView, context: Context) {
        view.show(text, marks: marks, style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HistoryPlainCopyTextView, context: Context) -> CGSize? {
        view.size(forWidth: proposal.width)
    }
}

final class HistoryPlainCopyTextView: NSTextView {
    private var shown: (text: String, marks: [Range<String.Index>], style: HistoryComparisonTextView.MarkStyle)?
    private var measured: (width: CGFloat, size: CGSize)?

    init() {
        // TextKit 1 measures the height for SwiftUI without switching layout systems later.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        importsGraphics = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Only the plain-text type. AppKit lists it under the legacy name `NSStringPboardType`
    /// here, and writes nothing for `.string`.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { $0 == .string || $0.rawValue == "NSStringPboardType" }
    }

    func show(_ text: String, marks: [Range<String.Index>], style: HistoryComparisonTextView.MarkStyle) {
        if let shown, shown.text == text, shown.marks == marks, shown.style == style { return }
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let marked: [NSAttributedString.Key: Any] = switch style {
        case .removed: [
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.22),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]
        case .added: [
            .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.38),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        }
        let content = NSMutableAttributedString(string: text, attributes: base)
        for mark in marks where mark.upperBound <= text.endIndex {
            content.addAttributes(marked, range: NSRange(mark, in: text))
        }
        if shown?.text != text { setSelectedRange(NSRange(location: 0, length: 0)) }
        textStorage?.setAttributedString(content)
        shown = (text, marks, style)
        measured = nil
    }

    /// The height of the text wrapped to the proposed width; without one, its unwrapped size.
    func size(forWidth proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth.flatMap { $0.isFinite ? max($0, 1) : nil }
        let wrapWidth = width ?? CGFloat.greatestFiniteMagnitude
        if let measured, measured.width == wrapWidth { return measured.size }
        guard let layoutManager, let textContainer else { return .zero }
        let previous = textContainer.containerSize
        textContainer.containerSize = NSSize(width: wrapWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        textContainer.containerSize = previous
        let size = CGSize(width: width ?? ceil(used.width), height: ceil(used.height))
        measured = (wrapWidth, size)
        return size
    }
}
