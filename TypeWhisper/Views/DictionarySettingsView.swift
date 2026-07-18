import SwiftUI
import TypeWhisperPluginSDK

private func dictionaryReplacementDisplayText(_ replacement: String) -> String {
    replacement.isEmpty ? "\"\"" : replacement
}

struct DictionarySettingsView: View {
    @ObservedObject private var viewModel = DictionaryViewModel.shared
    @ObservedObject private var termPackRegistryService: TermPackRegistryService
    @ObservedObject private var pluginManager: PluginManager
    @ObservedObject private var trainingService = ServiceContainer.shared.dictionaryTrainingService
    @State private var expandedCorrectionGroups = Set<String>()
    @State private var isTrainingPresented = false

    init() {
        _termPackRegistryService = ObservedObject(wrappedValue: TermPackRegistryService.shared)
        _pluginManager = ObservedObject(wrappedValue: PluginManager.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Dictionary"))
            Divider()

            dictionaryHeader

            if viewModel.filterTab == .termPacks {
                termPacksView
            } else if viewModel.entries.isEmpty {
                emptyState
            } else {
                dictionarySearchField
                dictionaryEntriesView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $viewModel.isEditing) {
            DictionaryEditorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isTrainingPresented, onDismiss: {
            Task { await trainingService.cancel() }
        }) {
            DictionaryTrainingSheet(
                service: trainingService,
                dismiss: { isTrainingPresented = false }
            )
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearError() }
        } message: {
            Text(viewModel.error ?? "")
        }
        .alert(String(localized: "Import Complete"), isPresented: Binding(
            get: { viewModel.importMessage != nil },
            set: { if !$0 { viewModel.clearImportMessage() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearImportMessage() }
        } message: {
            Text(viewModel.importMessage ?? "")
        }
        .alert(
            resetConfirmationTitle,
            isPresented: Binding(
                get: { viewModel.pendingResetRequest != nil },
                set: { if !$0 { viewModel.cancelReset() } }
            )
        ) {
            if let request = viewModel.pendingResetRequest {
                Button(resetConfirmationButtonTitle(for: request.action), role: .destructive) {
                    viewModel.confirmReset()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                viewModel.cancelReset()
            }
        } message: {
            if let request = viewModel.pendingResetRequest {
                Text(resetConfirmationMessage(for: request))
            }
        }
    }

    private var dictionaryHeader: some View {
        HStack {
            Picker("", selection: $viewModel.filterTab) {
                Text(String(localized: "All")).tag(DictionaryViewModel.FilterTab.all)
                Text(String(localized: "Terms")).tag(DictionaryViewModel.FilterTab.terms)
                Text(String(localized: "Corrections")).tag(DictionaryViewModel.FilterTab.corrections)
                Text(String(localized: "Auto-learned")).tag(DictionaryViewModel.FilterTab.autoLearned)
                Text(String(localized: "Term Packs")).tag(DictionaryViewModel.FilterTab.termPacks)
            }
            .pickerStyle(.segmented)
            .frame(width: 470)

            Spacer()

            if viewModel.filterTab != .termPacks {
                Button {
                    trainingService.reset()
                    isTrainingPresented = true
                } label: {
                    Label(
                        localizedAppText("Train Word...", de: "Wort trainieren..."),
                        systemImage: "mic.badge.plus"
                    )
                }
                Button {
                    viewModel.startCreating(type: .correction)
                } label: {
                    Label(String(localized: "Correction"), systemImage: "plus")
                }
                Button {
                    viewModel.startCreating(type: .term)
                } label: {
                    Label(String(localized: "Term"), systemImage: "plus")
                }
            }

            Menu {
                Button {
                    viewModel.exportDictionary()
                } label: {
                    Label(String(localized: "Export..."), systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.entries.isEmpty)

                Button {
                    viewModel.importDictionary()
                } label: {
                    Label(String(localized: "Import..."), systemImage: "square.and.arrow.down")
                }

                Divider()

                resetMenuButton(.clearAutoLearnedCorrections)
                resetMenuButton(.resetCustomDictionary)
                resetMenuButton(.deactivateAllTermPacks)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
        .padding(.vertical, SettingsLayoutMetrics.sectionSpacing)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func resetMenuButton(_ action: DictionaryResetAction) -> some View {
        let request = viewModel.resetRequest(for: action)
        Button(role: .destructive) {
            viewModel.requestReset(action)
        } label: {
            Label(resetMenuTitle(for: action), systemImage: resetMenuIcon(for: action))
        }
        .disabled(!request.canPerform)
    }

    private func resetMenuTitle(for action: DictionaryResetAction) -> String {
        switch action {
        case .clearAutoLearnedCorrections:
            return localizedAppText(
                "Clear Auto-Learned Corrections...",
                de: "Automatisch gelernte Korrekturen löschen..."
            )
        case .resetCustomDictionary:
            return localizedAppText(
                "Reset Custom Dictionary...",
                de: "Eigenes Dictionary zurücksetzen..."
            )
        case .deactivateAllTermPacks:
            return localizedAppText(
                "Deactivate All Term Packs...",
                de: "Alle Begriff-Pakete deaktivieren..."
            )
        }
    }

    private func resetMenuIcon(for action: DictionaryResetAction) -> String {
        switch action {
        case .clearAutoLearnedCorrections:
            return "wand.and.stars"
        case .resetCustomDictionary:
            return "trash"
        case .deactivateAllTermPacks:
            return "shippingbox.and.arrow.backward"
        }
    }

    private var resetConfirmationTitle: String {
        guard let action = viewModel.pendingResetRequest?.action else { return "" }
        switch action {
        case .clearAutoLearnedCorrections:
            return localizedAppText(
                "Clear Auto-Learned Corrections?",
                de: "Automatisch gelernte Korrekturen löschen?"
            )
        case .resetCustomDictionary:
            return localizedAppText(
                "Reset Custom Dictionary?",
                de: "Eigenes Dictionary zurücksetzen?"
            )
        case .deactivateAllTermPacks:
            return localizedAppText(
                "Deactivate All Term Packs?",
                de: "Alle Begriff-Pakete deaktivieren?"
            )
        }
    }

    private func resetConfirmationButtonTitle(for action: DictionaryResetAction) -> String {
        switch action {
        case .clearAutoLearnedCorrections:
            return localizedAppText("Clear Corrections", de: "Korrekturen löschen")
        case .resetCustomDictionary:
            return localizedAppText("Reset Dictionary", de: "Dictionary zurücksetzen")
        case .deactivateAllTermPacks:
            return localizedAppText("Deactivate Packs", de: "Pakete deaktivieren")
        }
    }

    private func resetConfirmationMessage(for request: DictionaryResetRequest) -> String {
        switch request.action {
        case .clearAutoLearnedCorrections:
            return localizedAppText(
                "This deletes \(request.autoLearnedCorrectionCount) auto-learned corrections. Manual entries and term packs remain unchanged. This cannot be undone.",
                de: "Dadurch werden \(request.autoLearnedCorrectionCount) automatisch gelernte Korrekturen gelöscht. Manuelle Einträge und Begriff-Pakete bleiben unverändert. Dies kann nicht rückgängig gemacht werden."
            )
        case .resetCustomDictionary:
            return localizedAppText(
                "This deletes \(request.termCount) custom terms, \(request.manualCorrectionCount) manual corrections, and \(request.autoLearnedCorrectionCount) auto-learned corrections. \(request.activePackCount) active term packs and their entries remain unchanged. This cannot be undone.",
                de: "Dadurch werden \(request.termCount) eigene Begriffe, \(request.manualCorrectionCount) manuelle Korrekturen und \(request.autoLearnedCorrectionCount) automatisch gelernte Korrekturen gelöscht. \(request.activePackCount) aktive Begriff-Pakete und deren Einträge bleiben unverändert. Dies kann nicht rückgängig gemacht werden."
            )
        case .deactivateAllTermPacks:
            return localizedAppText(
                "This deactivates \(request.activePackCount) term packs and removes \(request.termCount) pack terms and \(request.correctionCount) pack corrections. Custom and auto-learned entries remain unchanged.",
                de: "Dadurch werden \(request.activePackCount) Begriff-Pakete deaktiviert sowie \(request.termCount) Paket-Begriffe und \(request.correctionCount) Paket-Korrekturen entfernt. Eigene und automatisch gelernte Einträge bleiben unverändert."
            )
        }
    }

    private var dictionarySearchField: some View {
        NativeSearchField(
            text: $viewModel.searchQuery,
            placeholder: String(localized: "Search...")
        )
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
        .padding(.vertical, 8)
    }

    private var dictionaryEntriesView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !engineSupportRows.isEmpty {
                    DictionaryEngineSupportSection(rows: engineSupportRows)
                }

                if viewModel.filteredListRows.isEmpty {
                    dictionaryEntriesEmptyState
                } else {
                    ForEach(viewModel.filteredListRows) { listRow in
                        dictionaryListRow(listRow)
                    }
                }
            }
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
    }

    @ViewBuilder
    private func dictionaryListRow(_ listRow: DictionaryListRow) -> some View {
        switch listRow {
        case .entry(let row):
            DictionaryCardView(
                row: row,
                setEntryEnabled: { viewModel.setEntryEnabled(id: row.id, enabled: $0) },
                editEntry: { viewModel.startEditingEntry(id: row.id) },
                deleteEntry: { viewModel.deleteEntry(id: row.id) }
            )

        case .correctionGroup(let group):
            if group.aliases.count == 1, let row = group.aliases.first {
                DictionaryCardView(
                    row: row,
                    setEntryEnabled: { viewModel.setEntryEnabled(id: row.id, enabled: $0) },
                    editEntry: { viewModel.startEditingEntry(id: row.id) },
                    deleteEntry: { viewModel.deleteEntry(id: row.id) },
                    addAlias: { viewModel.startCreatingCorrectionAlias(replacement: group.replacement) }
                )
            } else {
                DictionaryCorrectionGroupCardView(
                    group: group,
                    isExpanded: correctionGroupExpansionBinding(for: group.replacement),
                    setEntryEnabled: { id, enabled in
                        viewModel.setEntryEnabled(id: id, enabled: enabled)
                    },
                    editEntry: { viewModel.startEditingEntry(id: $0) },
                    deleteEntry: { viewModel.deleteEntry(id: $0) },
                    addAlias: { viewModel.startCreatingCorrectionAlias(replacement: group.replacement) }
                )
            }
        }
    }

    private func correctionGroupExpansionBinding(for replacement: String) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.hasActiveSearch || expandedCorrectionGroups.contains(replacement)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedCorrectionGroups.insert(replacement)
                } else {
                    expandedCorrectionGroups.remove(replacement)
                }
            }
        )
    }

    private var dictionaryEntriesEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.hasActiveSearch
                ? "magnifyingglass"
                : "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            if viewModel.hasActiveSearch {
                Text(localizedAppText("No search results", de: "Keine Suchergebnisse"))
                    .font(.headline)
                Text(localizedAppText(
                    "Try a different search term or filter.",
                    de: "Versuche einen anderen Suchbegriff oder Filter."
                ))
                .font(.caption)
            } else {
                Text(String(localized: "No entries for this filter"))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var emptyState: some View {
        SettingsEmptyState(
            systemImage: "character.book.closed",
            title: String(localized: "No dictionary entries"),
            message: String(localized: "Terms help only on engines that support transcription-time biasing. Corrections always run after transcription and apply across engines.")
        ) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(String(localized: "Add Term")) {
                        viewModel.startCreating(type: .term)
                    }
                    Button(String(localized: "Add Correction")) {
                        viewModel.startCreating(type: .correction)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()
                    .padding(.vertical, 8)
                    .frame(maxWidth: 200)

                Button {
                    viewModel.filterTab = .termPacks
                } label: {
                    Label(String(localized: "Browse Term Packs"), systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)

                Text(String(localized: "Pre-built collections of technical terms for common domains"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.importDictionary()
                } label: {
                    Label(String(localized: "Import Dictionary..."), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var termPacksView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Built-in Packs
                ForEach(viewModel.visibleBuiltInPacks) { pack in
                    TermPackCardView(pack: pack, viewModel: viewModel)
                }

                // Community Packs
                communityPacksSection
            }
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
    }

    @ViewBuilder
    private var communityPacksSection: some View {
        Section {
            switch termPackRegistryService.fetchState {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Text(String(localized: "Loading community packs..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 12)

            case .error(let message):
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text(String(localized: "Failed to load community packs."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Button(String(localized: "Retry")) {
                            Task { await termPackRegistryService.fetchRegistry(force: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)

            case .loaded:
                if viewModel.visibleCommunityPacks.isEmpty {
                    HStack {
                        Spacer()
                        Text(String(localized: "No community packs available yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(viewModel.visibleCommunityPacks) { pack in
                        TermPackCardView(pack: pack, viewModel: viewModel)
                    }
                }
            }
        } header: {
            Text(String(localized: "Community Packs"))
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
        .task {
            await termPackRegistryService.fetchRegistry()
        }
    }

    private var engineSupportRows: [DictionaryEngineSupportRow] {
        pluginManager.transcriptionEngines
            .map {
                DictionaryEngineSupportRow(
                    engineName: $0.providerDisplayName,
                    support: ($0 as? any DictionaryTermsCapabilityProviding)?.dictionaryTermsSupport ?? .unsupported
                )
            }
            .sorted { $0.engineName.localizedCaseInsensitiveCompare($1.engineName) == .orderedAscending }
    }
}

private struct DictionaryTrainingSheet: View {
    @ObservedObject var service: DictionaryTrainingService
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            trainingHeader
            Divider()
            stageContent
            Divider()
            trainingFooter
        }
        .frame(width: 700, height: 620)
        .interactiveDismissDisabled(service.activeSampleID != nil)
    }

    private var trainingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    localizedAppText("Train a Word", de: "Wort trainieren"),
                    systemImage: "waveform.and.mic"
                )
                .font(.title2.weight(.semibold))
                Spacer()
                Text(stageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let snapshot = service.engineSnapshot {
                HStack(spacing: 16) {
                    Label(snapshot.engineName, systemImage: "cpu")
                    Label(snapshot.modelName, systemImage: "shippingbox")
                    Label(languageLabel(snapshot.languageSelection), systemImage: "globe")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch service.stage {
        case .word:
            wordStage
        case .samples:
            samplesStage
        case .review:
            reviewStage
        case .summary:
            summaryStage
        }
    }

    private var wordStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            ContentUnavailableView(
                localizedAppText("Choose the target word", de: "Zielwort auswählen"),
                systemImage: "character.cursor.ibeam",
                description: Text(localizedAppText(
                    "TypeWhisper will record three editable example sentences and inspect only the raw transcription. Nothing is saved until you confirm the review.",
                    de: "TypeWhisper nimmt drei editierbare Beispielsätze auf und prüft nur die rohe Transkription. Bis zur Bestätigung der Prüfung wird nichts gespeichert."
                ))
            )

            TextField(
                localizedAppText("Target word", de: "Zielwort"),
                text: $service.canonicalWord
            )
            .textFieldStyle(.roundedBorder)
            .font(.title3)

            if let error = service.errorMessage {
                errorLabel(error)
            }
            Spacer()
        }
        .padding(24)
    }

    private var samplesStage: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(service.samples) { sample in
                    trainingSampleCard(sample)
                }
                if let error = service.errorMessage {
                    errorLabel(error)
                }
            }
            .padding(20)
        }
    }

    private func trainingSampleCard(_ sample: DictionaryTrainingSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localizedAppText("Sample", de: "Beispiel") + " \(sampleNumber(sample.id))")
                    .font(.headline)
                Spacer()
                sampleStateLabel(sample.state)
            }

            TextField(
                localizedAppText("Example sentence", de: "Beispielsatz"),
                text: Binding(
                    get: { sample.sentence },
                    set: { service.updateSentence(id: sample.id, sentence: $0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .disabled(
                sample.state == .preparing ||
                    sample.state == .recording ||
                    sample.state == .transcribing
            )

            if let transcript = sample.transcript {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedAppText("Raw transcript", de: "Rohtranskript"))
                        .font(.caption.weight(.semibold))
                    Text(transcript)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                if sample.state == .recording {
                    Button {
                        Task { await service.stopRecordingAndTranscribe(sampleID: sample.id) }
                    } label: {
                        Label(localizedAppText("Stop", de: "Stopp"), systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task { await service.startRecording(sampleID: sample.id) }
                    } label: {
                        Label(
                            sample.state == .completed
                                ? localizedAppText("Record Again", de: "Erneut aufnehmen")
                                : localizedAppText("Record", de: "Aufnehmen"),
                            systemImage: "record.circle"
                        )
                    }
                    .disabled(service.activeSampleID != nil || sample.state == .transcribing)
                }

                if case .failed = sample.state {
                    Button(localizedAppText("Retry", de: "Wiederholen")) {
                        service.retrySample(id: sample.id)
                    }
                    .disabled(service.activeSampleID != nil)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var reviewStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedAppText(
                    "Review the unique misrecognitions. Conflicts are never overwritten.",
                    de: "Prüfe die eindeutigen Fehlerkennungen. Konflikte werden niemals überschrieben."
                ))
                .foregroundStyle(.secondary)

                if service.candidates.isEmpty {
                    ContentUnavailableView(
                        localizedAppText("No correction candidates", de: "Keine Korrekturkandidaten"),
                        systemImage: "checkmark.circle",
                        description: Text(localizedAppText(
                            "The target word can still be added as a dictionary term.",
                            de: "Das Zielwort kann trotzdem als Dictionary-Begriff hinzugefügt werden."
                        ))
                    )
                } else {
                    ForEach(service.candidates) { candidate in
                        candidateRow(candidate)
                    }
                }

                if let error = service.errorMessage {
                    errorLabel(error)
                }
            }
            .padding(20)
        }
    }

    private func candidateRow(_ candidate: DictionaryTrainingCandidate) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { candidate.isSelected },
                set: { service.setCandidateSelected(id: candidate.id, selected: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel(localizedAppText(
                "Include \(candidate.original) as a correction",
                de: "\(candidate.original) als Korrektur einschließen"
            ))
            .disabled(candidate.disposition != .available)

            TextField(
                localizedAppText("Misrecognition", de: "Fehlerkennung"),
                text: Binding(
                    get: { candidate.original },
                    set: { service.updateCandidate(id: candidate.id, original: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(service.canonicalWord)
                .fontWeight(.medium)
                .frame(minWidth: 100, alignment: .leading)
            candidateDispositionLabel(candidate.disposition)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var summaryStage: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                localizedAppText("Training complete", de: "Training abgeschlossen"),
                systemImage: "checkmark.circle.fill",
                description: Text(summaryDescription)
            )
            if let snapshot = service.engineSnapshot {
                Text(localizedAppText(
                    "Candidates were produced by \(snapshot.engineName) / \(snapshot.modelName). Corrections remain global.",
                    de: "Die Kandidaten wurden von \(snapshot.engineName) / \(snapshot.modelName) erzeugt. Korrekturen bleiben global."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trainingFooter: some View {
        HStack {
            if service.stage == .review {
                Button(localizedAppText("Back", de: "Zurück")) {
                    service.returnToSamples()
                }
            }

            Spacer()

            Button(service.stage == .summary
                ? localizedAppText("Done", de: "Fertig")
                : localizedAppText("Cancel", de: "Abbrechen")) {
                Task {
                    await service.cancel()
                    dismiss()
                }
            }

            switch service.stage {
            case .word:
                Button(localizedAppText("Continue", de: "Weiter")) {
                    service.beginTraining()
                }
                .buttonStyle(.borderedProminent)
            case .samples:
                Button(localizedAppText("Review", de: "Prüfen")) {
                    service.proceedToReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!service.canProceedToReview)
            case .review:
                Button(localizedAppText("Add to Dictionary", de: "Zum Dictionary hinzufügen")) {
                    service.confirm()
                }
                .buttonStyle(.borderedProminent)
            case .summary:
                EmptyView()
            }
        }
        .padding(16)
    }

    private var stageLabel: String {
        switch service.stage {
        case .word: localizedAppText("1 of 4 · Word", de: "1 von 4 · Wort")
        case .samples: localizedAppText("2 of 4 · Samples", de: "2 von 4 · Beispiele")
        case .review: localizedAppText("3 of 4 · Review", de: "3 von 4 · Prüfung")
        case .summary: localizedAppText("4 of 4 · Summary", de: "4 von 4 · Zusammenfassung")
        }
    }

    private var summaryDescription: String {
        guard let summary = service.summary else { return "" }
        let termText = summary.addedTerm
            ? localizedAppText("The target word was added as a term.", de: "Das Zielwort wurde als Begriff hinzugefügt.")
            : localizedAppText("The target word already existed.", de: "Das Zielwort war bereits vorhanden.")
        return termText + " " + localizedAppText(
            "Added \(summary.addedCorrections.count) corrections, skipped \(summary.duplicateCorrections.count) duplicates and \(summary.conflictingCorrections.count) conflicts.",
            de: "\(summary.addedCorrections.count) Korrekturen hinzugefügt, \(summary.duplicateCorrections.count) Duplikate und \(summary.conflictingCorrections.count) Konflikte übersprungen."
        )
    }

    private func sampleNumber(_ id: UUID) -> Int {
        (service.samples.firstIndex(where: { $0.id == id }) ?? 0) + 1
    }

    private func languageLabel(_ selection: LanguageSelection) -> String {
        switch selection {
        case .auto, .inheritGlobal:
            return localizedAppText("Automatic language", de: "Automatische Sprache")
        case .exact(let code):
            return code
        case .hints(let codes):
            return codes.joined(separator: ", ")
        }
    }

    @ViewBuilder
    private func sampleStateLabel(_ state: DictionaryTrainingSampleState) -> some View {
        switch state {
        case .pending:
            Label(localizedAppText("Ready", de: "Bereit"), systemImage: "circle")
                .foregroundStyle(.secondary)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(localizedAppText("Preparing", de: "Vorbereitung"))
            }
        case .recording:
            Label(localizedAppText("Recording", de: "Aufnahme"), systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(localizedAppText("Transcribing", de: "Transkription"))
            }
        case .completed:
            Label(localizedAppText("Complete", de: "Fertig"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func candidateDispositionLabel(_ disposition: DictionaryTrainingCandidateDisposition) -> some View {
        switch disposition {
        case .available:
            Label(localizedAppText("New", de: "Neu"), systemImage: "plus.circle")
                .foregroundStyle(.green)
        case .duplicate:
            Label(localizedAppText("Duplicate", de: "Duplikat"), systemImage: "equal.circle")
                .foregroundStyle(.secondary)
        case .conflict(let replacement):
            Label(
                localizedAppText("Conflict: \(replacement)", de: "Konflikt: \(replacement)"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .invalid:
            Label(localizedAppText("Invalid", de: "Ungültig"), systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

private struct DictionaryEngineSupportRow: Identifiable {
    let engineName: String
    let support: DictionaryTermsSupport

    var id: String { engineName }

    var badgeText: LocalizedStringKey {
        switch support {
        case .supported:
            return "Terms + Corrections"
        case .requiresPluginSetting:
            return "Terms requires plugin setting"
        case .unsupported:
            return "Corrections only"
        }
    }

    var tint: Color {
        switch support {
        case .supported:
            return .accentColor
        case .requiresPluginSetting:
            return .orange
        case .unsupported:
            return .secondary
        }
    }

    var detailText: LocalizedStringKey? {
        switch support {
        case .supported:
            return nil
        case .requiresPluginSetting:
            if engineName == "Parakeet" {
                return "Terms work only when Vocabulary Boosting is enabled in the Parakeet plugin settings."
            }
            return "This engine needs an extra plugin setting before Terms are applied."
        case .unsupported:
            if engineName == "Cohere" {
                return "Cohere currently ignores Terms. Dictionary Corrections still apply after transcription."
            }
            return "This engine currently uses Dictionary Corrections only."
        }
    }
}

private struct DictionaryEngineSupportSection: View {
    let rows: [DictionaryEngineSupportRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Engine Support"))
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(String(localized: "Terms depend on engine support. Corrections always run after transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(row.engineName)
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            Text(row.badgeText)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(row.tint.opacity(0.14))
                                .foregroundStyle(row.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }

                        if let detailText = row.detailText {
                            Text(detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }
            }
        }
    }
}

// MARK: - Term Pack Card

private struct TermPackCardView: View {
    let pack: TermPack
    @ObservedObject var viewModel: DictionaryViewModel
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isActivated: Bool {
        viewModel.isPackActivated(pack)
    }

    private var showUpdate: Bool {
        isActivated && viewModel.hasUpdate(for: pack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: pack.icon)
                    .font(.title3)
                    .foregroundStyle(isActivated ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pack.name)
                            .font(.callout)
                            .fontWeight(.medium)

                        if showUpdate {
                            Text(String(localized: "Update Available"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    HStack(spacing: 4) {
                        Text(pack.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if pack.source == .community, let author = pack.author {
                            Text("-")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "by \(author)"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Text(String(localized: "\(pack.entryCount) entries"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if showUpdate {
                    Button(String(localized: "Update")) {
                        viewModel.updatePack(pack)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                Toggle("", isOn: Binding(
                    get: { isActivated },
                    set: { _ in viewModel.togglePack(pack) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Enable \(pack.name)"))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Show terms for \(pack.name)"))
                .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 8) {
                    if !pack.terms.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(pack.terms, id: \.self) { term in
                                Text(term)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }

                    if !pack.corrections.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(pack.corrections, id: \.self) { correction in
                                HStack(spacing: 4) {
                                    Text(correction.original)
                                        .strikethrough()
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(dictionaryReplacementDisplayText(correction.replacement))
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Dictionary Card

private struct DictionaryCardView: View {
    let row: DictionaryEntryRow
    let setEntryEnabled: (Bool) -> Void
    let editEntry: () -> Void
    let deleteEntry: () -> Void
    var addAlias: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(row.type.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(row.type == .correction ? Color.orange : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((row.type == .correction ? Color.orange : Color.accentColor).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            if row.type == .correction, let replacement = row.replacementDisplayText {
                Text(row.original)
                    .font(.callout)
                    .strikethrough()
                    .foregroundStyle(.secondary)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(replacement)
                    .font(.callout)
                    .fontWeight(.medium)
            } else {
                Text(row.original)
                    .font(.callout)
                    .fontWeight(.medium)

                DictionaryBoostingBadge(
                    label: row.termBoostingLabel,
                    value: row.formattedCtcMinSimilarity
                )
            }

            if row.caseSensitive {
                Text("Aa")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if row.source == .autoLearned {
                DictionarySourceBadge()
            }

            Spacer()

            if let addAlias, row.type == .correction, !(row.replacement?.isEmpty ?? true) {
                Button {
                    addAlias()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(localizedAppText("Add alias", de: "Variante hinzufügen"))
                .accessibilityLabel(localizedAppText("Add alias", de: "Variante hinzufügen"))
            }

            Toggle("", isOn: Binding(
                get: { row.isEnabled },
                set: { setEntryEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(row.original)"))
            .onTapGesture {}
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            editEntry()
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(String(localized: "Edit")) {
                editEntry()
            }
            if let addAlias {
                Button(localizedAppText("Add Alias", de: "Variante hinzufügen")) {
                    addAlias()
                }
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                deleteEntry()
            }
        }
    }
}

private struct DictionaryCorrectionGroupCardView: View {
    let group: DictionaryCorrectionGroupRow
    @Binding var isExpanded: Bool
    let setEntryEnabled: (UUID, Bool) -> Void
    let editEntry: (UUID) -> Void
    let deleteEntry: (UUID) -> Void
    let addAlias: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 0) {
                    ForEach(Array(group.aliases.enumerated()), id: \.element.id) { index, alias in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 28)
                        }

                        DictionaryCorrectionAliasRow(
                            row: alias,
                            setEntryEnabled: { setEntryEnabled(alias.id, $0) },
                            editEntry: { editEntry(alias.id) },
                            deleteEntry: { deleteEntry(alias.id) }
                        )
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Text(String(localized: "Correction"))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    Text(group.replacementDisplayText)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(localizedAppText(
                        "\(group.aliases.count) variants",
                        de: "\(group.aliases.count) Varianten"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Capsule())
                }
            }

            Button {
                addAlias()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(localizedAppText("Add alias", de: "Variante hinzufügen"))
            .accessibilityLabel(localizedAppText("Add alias", de: "Variante hinzufügen"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            Button(localizedAppText("Add Alias", de: "Variante hinzufügen")) {
                addAlias()
            }
        }
    }
}

private struct DictionaryCorrectionAliasRow: View {
    let row: DictionaryEntryRow
    let setEntryEnabled: (Bool) -> Void
    let editEntry: () -> Void
    let deleteEntry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 18)

            Text(row.original)
                .font(.callout)
                .strikethrough()
                .foregroundStyle(row.isEnabled ? .primary : .secondary)

            if row.caseSensitive {
                Text("Aa")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            if row.source == .autoLearned {
                DictionarySourceBadge()
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { row.isEnabled },
                set: { setEntryEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(row.original)"))
            .onTapGesture {}
        }
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            editEntry()
        }
        .contextMenu {
            Button(String(localized: "Edit")) {
                editEntry()
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                deleteEntry()
            }
        }
    }
}

private struct DictionarySourceBadge: View {
    var body: some View {
        Label(String(localized: "Auto-learned"), systemImage: "wand.and.sparkles")
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(Color.yellow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct DictionaryBoostingBadge: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption2)
            Text(value.isEmpty ? label : "\(label) \(value)")
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Editor Sheet

private struct DictionaryEditorSheet: View {
    @ObservedObject var viewModel: DictionaryViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case original, replacement
    }

    private var title: String {
        if viewModel.lockedCorrectionReplacement != nil {
            return localizedAppText("Add Correction Alias", de: "Korrekturvariante hinzufügen")
        }
        if viewModel.isCreatingNew {
            return viewModel.editType == .term
                ? String(localized: "New Term")
                : String(localized: "New Correction")
        }
        return viewModel.editType == .term
            ? String(localized: "Edit Term")
            : String(localized: "Edit Correction")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                Text(viewModel.editType == .term
                     ? String(localized: "Terms are sent only to engines that support transcription-time biasing")
                     : String(localized: "Corrections replace text after transcription"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox(viewModel.editType == .term ? String(localized: "Term") : String(localized: "Correction")) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.editType == .term ? String(localized: "Term") : String(localized: "Wrong Text"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(
                                viewModel.editType == .term
                                    ? String(localized: "e.g. Kubernetes")
                                    : String(localized: "e.g. kubernetees"),
                                text: $viewModel.editOriginal
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .original)
                        }

                        if viewModel.editType == .correction {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Correct Text"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(String(localized: "e.g. Kubernetes"), text: $viewModel.editReplacement)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .replacement)
                                    .disabled(viewModel.lockedCorrectionReplacement != nil)

                                if viewModel.lockedCorrectionReplacement != nil {
                                    Text(localizedAppText(
                                        "The correct text is fixed by the selected group.",
                                        de: "Der korrekte Text wird von der ausgewählten Gruppe vorgegeben."
                                    ))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Toggle(String(localized: "Case sensitive"), isOn: $viewModel.editCaseSensitive)
                    }
                    .padding(.vertical, 8)
                }

                if viewModel.editType == .term {
                    GroupBox(String(localized: "Boosting")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(String(localized: "Boosting"), selection: $viewModel.editTermBoostingMode) {
                                ForEach(DictionaryViewModel.TermBoostingMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            if viewModel.editTermBoostingMode == .advanced {
                                HStack(spacing: 10) {
                                    Text(String(localized: "Threshold"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Slider(
                                        value: $viewModel.editAdvancedCtcMinSimilarity,
                                        in: DictionaryViewModel.minimumAdvancedCtcMinSimilarity...DictionaryViewModel.maximumAdvancedCtcMinSimilarity
                                    )

                                    Text(String(format: "%.2f", viewModel.editAdvancedCtcMinSimilarity))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .frame(width: 36, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    viewModel.cancelEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Save")) {
                    viewModel.saveEditing()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.editOriginal.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 430, height: viewModel.editType == .term ? 455 : 340)
        .onAppear {
            focusedField = .original
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
