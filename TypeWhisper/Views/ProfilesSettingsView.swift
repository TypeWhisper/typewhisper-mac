import SwiftUI

struct ProfilesSettingsView: View {
    @ObservedObject private var viewModel = ProfilesViewModel.shared
    @ObservedObject private var dictationViewModel = DictationViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let activeRuleName = dictationViewModel.activeRuleName {
                        ActiveRuleBanner(
                            ruleName: activeRuleName,
                            reasonLabel: dictationViewModel.activeRuleReasonLabel,
                            explanation: dictationViewModel.activeRuleExplanation
                        )
                    }

                    if viewModel.profiles.isEmpty {
                        emptyState
                    } else {
                        rulesList
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .sheet(isPresented: $viewModel.showingEditor) {
            RuleEditorSheet(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Regeln")
                    .font(.headline)
                Text("Wenn Kontext X erkannt wird, nutzt TypeWhisper Verhalten Y.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.prepareNewProfile()
            } label: {
                Label("Neue Regel", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Noch keine Regeln", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Regeln erklären TypeWhisper, wann welche Sprache, Engine oder Ausgabeform gelten soll.")
                Text("Beispiele: Slack -> Englisch mit Auto Enter, github.com -> Code-Prompt, Mail -> Deutsch mit Übersetzung.")
            }
            .frame(maxWidth: 420, alignment: .leading)
        } actions: {
            Button("Erste Regel erstellen") {
                viewModel.prepareNewProfile()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background {
            groupedListSurface(cornerRadius: 16)
        }
    }

    private var rulesList: some View {
        let indexedProfiles = Array(viewModel.profiles.enumerated())

        return LazyVStack(spacing: 0) {
            ForEach(indexedProfiles, id: \.element.id) { index, profile in
                RuleRow(profile: profile, viewModel: viewModel)

                if index < indexedProfiles.count - 1 {
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .background {
            groupedListSurface(cornerRadius: 14)
        }
    }
}

private struct ActiveRuleBanner: View {
    let ruleName: String
    let reasonLabel: String?
    let explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aktive Regel")
                .font(.headline)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ruleName)
                        .font(.title3.weight(.semibold))

                    if let explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let reasonLabel {
                    Text(reasonLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.blue.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(16)
        .background {
            groupedListSurface(cornerRadius: 16)
        }
    }
}

private struct RuleRow: View {
    let profile: Profile
    @ObservedObject var viewModel: ProfilesViewModel
    @State private var isDropTargeted = false
    @State private var isHovered = false
    @State private var isPressingReorderHandle = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                reorderPill

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.headline)

                        if let hotkey = profile.hotkey {
                            Text("Manuell: \(HotkeyService.displayName(for: hotkey))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(viewModel.ruleNarrative(for: profile))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text(viewModel.manualOverrideSummary(for: profile))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { profile.isEnabled },
                        set: { _ in viewModel.toggleProfile(profile) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()

                    HStack(spacing: 6) {
                        Button {
                            viewModel.prepareEditProfile(profile)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowHighlightColor)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            viewModel.prepareEditProfile(profile)
        }
        .draggable(profile.id.uuidString)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let droppedId = droppedItems.first,
                  let fromIndex = viewModel.profiles.firstIndex(where: { $0.id.uuidString == droppedId }),
                  let toIndex = viewModel.profiles.firstIndex(where: { $0.id == profile.id }) else {
                return false
            }

            viewModel.moveProfile(fromIndex: fromIndex, toIndex: toIndex)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .alert("Regel löschen?", isPresented: $showingDeleteConfirmation) {
            Button("Löschen", role: .destructive) {
                viewModel.deleteProfile(profile)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Möchtest du „\(profile.name)“ wirklich löschen?")
        }
    }

    private var rowHighlightColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.08)
        }

        if isHovered {
            return Color.white.opacity(0.025)
        }

        return Color.clear
    }

    private var reorderPill: some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.semibold))
            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.75))
            .frame(width: 18, height: 28)
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPressingReorderHandle ? Color.primary.opacity(0.08) : Color.clear)
            }
            .animation(.easeInOut(duration: 0.12), value: isPressingReorderHandle)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {} onPressingChanged: { isPressing in
                isPressingReorderHandle = isPressing
            }
            .help("Reihenfolge per Drag & Drop ändern")
    }
}

private struct RuleEditorSheet: View {
    @ObservedObject var viewModel: ProfilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RuleStepHeader(currentStep: viewModel.editorStep)

                    switch viewModel.editorStep {
                    case .scope:
                        RuleScopeStep(viewModel: viewModel)
                    case .behavior:
                        RuleBehaviorStep(viewModel: viewModel)
                    case .review:
                        RuleReviewStep(viewModel: viewModel)
                    }
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .frame(width: 700, height: 790)
        .background(sheetBackground)
        .sheet(isPresented: $viewModel.showingAppPicker) {
            AppPickerSheet(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                infoChip(viewModel.editingProfile == nil ? "Regel-Wizard" : "Regel anpassen", tint: .accentColor)

                Text(viewModel.editingProfile == nil ? "Neue Regel" : "Regel bearbeiten")
                    .font(.title2.weight(.semibold))

                Text("Von Kontext zu Verhalten in drei klaren Schritten.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                infoChip("Schritt \(currentStepNumber) von \(totalSteps)", tint: .orange)

                if viewModel.editorStep == .review {
                    Toggle("Aktiv", isOn: $viewModel.editorIsEnabled)
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schritt \(currentStepNumber) von \(totalSteps)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(stepGuidance)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button("Abbrechen") {
                dismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            if viewModel.editorStep != .scope {
                Button("Zurück") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.editorStep == .review {
                Button("Regel speichern") {
                    viewModel.saveProfile()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Weiter") {
                    viewModel.goToNextStep()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAdvanceFromCurrentStep)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.bar)
    }

    private var currentStepNumber: Int { viewModel.editorStep.rawValue + 1 }

    private var totalSteps: Int { RuleEditorStep.allCases.count }

    private var stepGuidance: String {
        switch viewModel.editorStep {
        case .scope:
            return viewModel.canAdvanceFromCurrentStep
                ? "Kontext steht. Du kannst jetzt das Verhalten festlegen."
                : "Wähle mindestens eine App oder Website, damit die Regel automatisch greifen kann."
        case .behavior:
            return "Lege fest, wie TypeWhisper in diesem Kontext reagieren soll."
        case .review:
            return "Prüfe Name, Matching und fortgeschrittene Optionen vor dem Speichern."
        }
    }

    private var sheetBackground: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)

            Rectangle()
                .fill(Color.accentColor.opacity(0.028))
                .frame(height: 150)
                .blur(radius: 30)
                .offset(y: -18)
        }
    }
}

private struct RuleStepHeader: View {
    let currentStep: RuleEditorStep

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(RuleEditorStep.allCases.enumerated()), id: \.element.rawValue) { index, step in
                stepItem(for: step)

                if index < RuleEditorStep.allCases.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func stepItem(for step: RuleEditorStep) -> some View {
        let isCurrent = step == currentStep
        let isCompleted = step.rawValue < currentStep.rawValue
        let isReachable = step.rawValue <= currentStep.rawValue

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(stepCircleFill(isCurrent: isCurrent, isCompleted: isCompleted))
                    .frame(width: 30, height: 30)

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isCurrent ? .white : .primary)
                }
            }

            Text(step.title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isReachable ? .primary : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
    }

    private func stepCircleFill(isCurrent: Bool, isCompleted: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        if isCompleted {
            return AnyShapeStyle(Color.accentColor.opacity(0.72))
        }

        return AnyShapeStyle(Color.primary.opacity(0.10))
    }

    private func stepBackground(isCurrent: Bool, isCompleted: Bool) -> some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor.opacity(0.12))
        }

        if isCompleted {
            return AnyShapeStyle(Color.accentColor.opacity(0.10))
        }

        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }
}

private struct RuleScopeStep: View {
    @ObservedObject var viewModel: ProfilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wo gilt diese Regel?")
                    .font(.title3.weight(.semibold))
                Text("Wähle mindestens eine App oder Website. Beides zusammen ergibt die spezifischste Regel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            card(
                title: "Apps",
                description: "Wähle die Apps, in denen diese Regel automatisch greifen darf.",
                icon: "square.stack.3d.up.fill",
                tint: .blue
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.editorBundleIdentifiers.isEmpty {
                        Text("Keine Apps ausgewählt.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.editorBundleIdentifiers, id: \.self) { bundleId in
                            HStack {
                                if let app = viewModel.installedApps.first(where: { $0.id == bundleId }) {
                                    if let icon = app.icon {
                                        Image(nsImage: icon)
                                    }
                                    Text(app.name)
                                } else {
                                    Text(bundleId)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    viewModel.editorBundleIdentifiers.removeAll { $0 == bundleId }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(10)
                            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    Button("Apps auswählen…") {
                        viewModel.appSearchQuery = ""
                        viewModel.showingAppPicker = true
                    }
                }
            }

            websiteScopeSection
        }
    }

    private var websiteToggleTitle: String {
        if let appName = viewModel.editorRelevantBrowserName {
            return "Website in \(appName) eingrenzen"
        }

        return "Optional: auf eine Website eingrenzen"
    }

    private var websiteToggleDescription: String {
        if let detectedDomain = viewModel.editorDetectedDomain, viewModel.editorDetectedIsSupportedBrowser {
            return "Aktuell erkannt: \(detectedDomain). Die Regel kann damit auf eine konkrete Seite oder Domain begrenzt werden."
        }

        if let appName = viewModel.editorRelevantBrowserName {
            return "\(appName) ist als Browser gewählt. Ergänze hier optional eine Domain, wenn die Regel nicht für alle Seiten gelten soll."
        }

        return "Domains sind nur nötig, wenn die Regel nicht für die ganze App, sondern nur für bestimmte Seiten gelten soll."
    }

    private var websiteScopeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.showingWebsiteScope.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                            .frame(width: 36, height: 36)

                        Image(systemName: "globe")
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(websiteToggleTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            if !viewModel.editorUrlPatterns.isEmpty {
                                infoChip("\(viewModel.editorUrlPatterns.count)", tint: .orange)
                            }
                        }

                        Text(websiteToggleDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Image(systemName: viewModel.showingWebsiteScope ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if viewModel.showingWebsiteScope {
                websiteScopeContent
            }
        }
        .padding(18)
        .background {
            elevatedPanel(cornerRadius: 20)
        }
    }

    private var websiteScopeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let detectedDomain = viewModel.editorDetectedDomain, viewModel.editorDetectedIsSupportedBrowser {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aktuelle Website")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(detectedDomain)
                            .font(.headline)

                        if let detectedURL = viewModel.editorDetectedURL {
                            Text(detectedURL)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer()

                    if !viewModel.editorUrlPatterns.contains(detectedDomain) {
                        Button("Domain übernehmen") {
                            viewModel.addDetectedDomainToEditor()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 14) {
                if viewModel.editorUrlPatterns.isEmpty {
                    Text("Keine Websites ausgewählt.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.editorUrlPatterns, id: \.self) { pattern in
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(.orange)
                            Text(pattern)
                            Spacer()
                            Button {
                                viewModel.editorUrlPatterns.removeAll { $0 == pattern }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                HStack {
                    TextField("z. B. github.com", text: $viewModel.urlPatternInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            viewModel.addUrlPattern()
                        }
                        .onChange(of: viewModel.urlPatternInput) {
                            viewModel.filterDomainSuggestions()
                        }

                    Button("Hinzufügen") {
                        viewModel.addUrlPattern()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.urlPatternInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !viewModel.domainSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.domainSuggestions, id: \.self) { domain in
                            Button {
                                viewModel.selectDomainSuggestion(domain)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "globe")
                                        .font(.caption)
                                    Text(domain)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Text("Subdomains werden automatisch mit eingeschlossen. `google.com` matcht also auch `docs.google.com`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RuleBehaviorStep: View {
    @ObservedObject var viewModel: ProfilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Wie soll TypeWhisper reagieren?")
                    .font(.title3.weight(.semibold))
                Text("Hier legst du Sprache, Prompt, Engine und Ausgabe für diesen Kontext fest. Priorität und manuelle Übersteuerung folgen erst im nächsten Schritt.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            card(
                title: "Sprache & Umwandlung",
                description: "Wie gesprochener Text verstanden und optional weiterverarbeitet wird.",
                icon: "waveform.badge.mic",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: "Gesprochene Sprache",
                        description: "Welche Sprache TypeWhisper in diesem Kontext erwarten soll."
                    ) {
                        Picker("Gesprochene Sprache", selection: $viewModel.editorInputLanguage) {
                            Text("Globale Einstellung").tag(nil as String?)
                            Divider()
                            Text("Automatisch erkennen").tag("auto" as String?)
                            Divider()
                            ForEach(viewModel.settingsViewModel.availableLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code as String?)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    #if canImport(Translation)
                    if #available(macOS 15, *) {
                        Divider()

                        settingRow(
                            title: "Übersetzung",
                            description: "Ob TypeWhisper den Text vor dem Einfügen automatisch übersetzen soll."
                        ) {
                            Picker("Übersetzung", selection: $viewModel.editorTranslationEnabled) {
                                Text("Globale Einstellung").tag(nil as Bool?)
                                Divider()
                                Text("Ein").tag(true as Bool?)
                                Text("Aus").tag(false as Bool?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if viewModel.editorTranslationEnabled != false {
                            Divider()

                            settingRow(
                                title: "Zielsprache",
                                description: "Welche Sprache nach der Übersetzung ausgegeben werden soll."
                            ) {
                                Picker("Zielsprache", selection: $viewModel.editorTranslationTargetLanguage) {
                                    Text("Globale Einstellung").tag(nil as String?)
                                    Divider()
                                    ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                                        Text(lang.name).tag(lang.code as String?)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    #endif

                    Divider()

                    settingRow(
                        title: "Prompt",
                        description: "Optionaler Nachbearbeitungsschritt für diese Regel."
                    ) {
                        Picker("Prompt", selection: $viewModel.editorPromptActionId) {
                            Text("Keiner").tag(nil as String?)
                            Divider()
                            ForEach(PromptActionsViewModel.shared.promptActions.filter(\.isEnabled)) { action in
                                Label(action.name, systemImage: action.icon).tag(action.id.uuidString as String?)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            card(
                title: "Engine & Modell",
                description: "Welche Engine diesen Kontext bevorzugt behandeln soll.",
                icon: "cpu",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: "Transkriptions-Engine",
                        description: "Welche Engine TypeWhisper hier bevorzugt verwenden soll."
                    ) {
                        Picker("Transkriptions-Engine", selection: $viewModel.editorEngineOverride) {
                            Text("Globale Einstellung").tag(nil as String?)
                            Divider()
                            ForEach(PluginManager.shared.transcriptionEngines, id: \.providerId) { engine in
                                Text(engine.providerDisplayName).tag(engine.providerId as String?)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    if let override = viewModel.editorEngineOverride,
                       let plugin = PluginManager.shared.transcriptionEngine(for: override) {
                        let models = plugin.transcriptionModels
                        if models.count > 1 {
                            Divider()

                            settingRow(
                                title: "Modell",
                                description: "Optionales Modell innerhalb der gewählten Engine."
                            ) {
                                Picker("Modell", selection: $viewModel.editorCloudModelOverride) {
                                    Text("Standard").tag(nil as String?)
                                    Divider()
                                    ForEach(models, id: \.id) { model in
                                        Text(model.displayName).tag(model.id as String?)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                }
            }

            card(
                title: "Ausgabe",
                description: "Wie das Ergebnis im Zielkontext eingefügt werden soll.",
                icon: "text.badge.checkmark",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: "Ausgabeformat",
                        description: "In welchem Format das Ergebnis eingefügt werden soll."
                    ) {
                        Picker("Ausgabeformat", selection: $viewModel.editorOutputFormat) {
                            Text("Keins").tag(nil as String?)
                            Divider()
                            Text("Automatisch erkennen").tag("auto" as String?)
                            Text("Markdown").tag("markdown" as String?)
                            Text("HTML").tag("html" as String?)
                            Text("Plain Text").tag("plaintext" as String?)
                            Text("Code").tag("code" as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Divider()

                    settingRow(
                        title: "Senden nach dem Einfügen",
                        description: "Drückt nach dem Einfügen automatisch Enter, wenn der Zielkontext das erwartet."
                    ) {
                        Toggle("Enter automatisch drücken", isOn: $viewModel.editorAutoEnterEnabled)
                    }
                }
            }
        }
    }
}

private struct RuleReviewStep: View {
    @ObservedObject var viewModel: ProfilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review & Erweitert")
                    .font(.title3.weight(.semibold))
                Text("Vergib zuerst einen Namen für die Regel. Danach siehst du die Vorschau, und alles Weitere ist optional.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            card(
                title: "Name",
                description: "Pflichtfeld für diese Regel.",
                icon: "text.cursor",
                tint: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(
                        "Regelname",
                        text: Binding(
                            get: { viewModel.currentRuleName },
                            set: { viewModel.updateRuleName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Toggle("Regel aktivieren", isOn: $viewModel.editorIsEnabled)
                }
            }

            card(
                title: "Vorschau",
                description: "So liest sich die Regel vor dem Speichern.",
                icon: "sparkles",
                tint: .accentColor
            ) {
                RulePreviewCard(
                    title: "Diese Regel macht Folgendes",
                    name: viewModel.currentRuleName,
                    narrative: viewModel.editorRuleNarrative
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.showingAdvancedSettings.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Erweiterte Optionen")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text("Manuelle Übersteuerung, Priorität, Memory und weitere Details.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Image(systemName: viewModel.showingAdvancedSettings ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if viewModel.showingAdvancedSettings {
                    VStack(alignment: .leading, spacing: 16) {
                        Divider()
                            .padding(.top, 12)

                        card(
                            title: "Manuelle Übersteuerung",
                            description: "Optional: erzwingt diese Regel unabhängig vom aktuellen Kontext.",
                            icon: "command",
                            tint: .accentColor
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                HotkeyRecorderView(
                                    label: viewModel.editorHotkeyLabel,
                                    title: "Manuelle Übersteuerung",
                                    onRecord: { hotkey in
                                        if let conflictId = ServiceContainer.shared.hotkeyService.isHotkeyAssignedToProfile(
                                            hotkey,
                                            excludingProfileId: viewModel.editingProfile?.id
                                        ) {
                                            if let conflictProfile = viewModel.profiles.first(where: { $0.id == conflictId }) {
                                                conflictProfile.hotkey = nil
                                            }
                                        }
                                        viewModel.editorHotkey = hotkey
                                        viewModel.editorHotkeyLabel = HotkeyService.displayName(for: hotkey)
                                    },
                                    onClear: {
                                        viewModel.editorHotkey = nil
                                        viewModel.editorHotkeyLabel = ""
                                    }
                                )

                                if let hotkey = viewModel.editorHotkey,
                                   let globalSlot = ServiceContainer.shared.hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
                                    Label(
                                        "Dieser Hotkey ist auch dem Slot \(globalSlot.rawValue) zugewiesen.",
                                        systemImage: "exclamationmark.triangle"
                                    )
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                }

                                Text(viewModel.editorManualOverrideSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        card(
                            title: "Erweitertes Verhalten",
                            description: "Nur für Power User. Diese Optionen ändern nicht das Matching, sondern das Verhalten nach dem Match.",
                            icon: "gearshape.2.fill",
                            tint: .teal
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Inline Commands", isOn: $viewModel.editorInlineCommandsEnabled)
                                Toggle("Memory", isOn: $viewModel.editorMemoryEnabled)

                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Reihenfolge")
                                        Text("Zwischen gleich spezifischen Regeln gewinnt die höher einsortierte Regel.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text("Per Drag & Drop")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                }

                                Text("Die Reihenfolge änderst du in der Regeln-Liste über die Ziehen-Pille.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .background {
                elevatedPanel(cornerRadius: 20)
            }
        }
    }
}

private struct RulePreviewCard: View {
    let title: String
    let name: String
    let narrative: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 42, height: 42)

                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(name)
                        .font(.title3.weight(.semibold))
                }

                Spacer()
            }

            Text(narrative)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background {
            elevatedPanel(cornerRadius: 22)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
        }
    }
}

private func card<Content: View>(
    title: String,
    description: String,
    icon: String = "square.stack.3d.up",
    tint: Color = .accentColor,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }

        content()
    }
    .padding(18)
    .background {
        elevatedPanel(cornerRadius: 20)
    }
}

private func infoChip(_ text: String, tint: Color) -> some View {
    Text(text)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
}

private func elevatedPanel(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
}

private func groupedListSurface(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color.white.opacity(0.022))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.038), lineWidth: 1)
        }
}

private func settingTile<Content: View>(
    title: String,
    icon: String,
    tint: Color,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }

        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(12)
    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(tint.opacity(0.12), lineWidth: 1)
    }
}

private func settingRow<Content: View>(
    title: String,
    description: String,
    @ViewBuilder content: () -> Content
) -> some View {
    HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 16)

        content()
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 260, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
}

private struct AppPickerSheet: View {
    @ObservedObject var viewModel: ProfilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps auswählen")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Apps durchsuchen…", text: $viewModel.appSearchQuery)
                    .textFieldStyle(.plain)
                if !viewModel.appSearchQuery.isEmpty {
                    Button {
                        viewModel.appSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)

            Divider()

            List(viewModel.filteredApps) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                    }
                    Text(app.name)

                    Spacer()

                    if viewModel.editorBundleIdentifiers.contains(app.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toggleAppInEditor(app.id)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Fertig") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }
}
