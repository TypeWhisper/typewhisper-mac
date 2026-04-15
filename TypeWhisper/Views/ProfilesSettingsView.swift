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
                Text(localizedAppText("Rules", de: "Regeln"))
                    .font(.headline)
                Text(localizedAppText(
                    "When context X is detected, TypeWhisper uses behavior Y.",
                    de: "Wenn Kontext X erkannt wird, nutzt TypeWhisper Verhalten Y."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.prepareNewProfile()
            } label: {
                Label(localizedAppText("New Rule", de: "Neue Regel"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localizedAppText("No Rules Yet", de: "Noch keine Regeln"), systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text(localizedAppText(
                    "Rules tell TypeWhisper which language, engine, or output format should apply in which context.",
                    de: "Regeln erklären TypeWhisper, wann welche Sprache, Engine oder Ausgabeform gelten soll."
                ))
                Text(localizedAppText(
                    "Examples: Slack -> English with Auto Enter, github.com -> code prompt, Mail -> German with translation.",
                    de: "Beispiele: Slack -> Englisch mit Auto Enter, github.com -> Code-Prompt, Mail -> Deutsch mit Übersetzung."
                ))
            }
            .frame(maxWidth: 420, alignment: .leading)
        } actions: {
            Button(localizedAppText("Create First Rule", de: "Erste Regel erstellen")) {
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
            Text(localizedAppText("Active Rule", de: "Aktive Regel"))
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
        .alert(localizedAppText("Delete rule?", de: "Regel löschen?"), isPresented: $showingDeleteConfirmation) {
            Button(localizedAppText("Delete", de: "Löschen"), role: .destructive) {
                viewModel.deleteProfile(profile)
            }
            Button(localizedAppText("Cancel", de: "Abbrechen"), role: .cancel) {}
        } message: {
            Text(localizedAppText(
                "Do you really want to delete “\(profile.name)”?",
                de: "Möchtest du „\(profile.name)“ wirklich löschen?"
            ))
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
            .help(localizedAppText("Change order via drag and drop", de: "Reihenfolge per Drag & Drop ändern"))
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
                infoChip(
                    viewModel.editingProfile == nil
                        ? localizedAppText("Rule Wizard", de: "Regel-Wizard")
                        : localizedAppText("Adjust Rule", de: "Regel anpassen"),
                    tint: .accentColor
                )

                Text(
                    viewModel.editingProfile == nil
                        ? localizedAppText("New Rule", de: "Neue Regel")
                        : localizedAppText("Edit Rule", de: "Regel bearbeiten")
                )
                .font(.title2.weight(.semibold))

                Text(localizedAppText(
                    "From context to behavior in three clear steps.",
                    de: "Von Kontext zu Verhalten in drei klaren Schritten."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                infoChip(
                    localizedAppText("Step \(currentStepNumber) of \(totalSteps)", de: "Schritt \(currentStepNumber) von \(totalSteps)"),
                    tint: .orange
                )

                if viewModel.editorStep == .review {
                    Toggle(localizedAppText("Active", de: "Aktiv"), isOn: $viewModel.editorIsEnabled)
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedAppText("Step \(currentStepNumber) of \(totalSteps)", de: "Schritt \(currentStepNumber) von \(totalSteps)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(stepGuidance)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(localizedAppText("Cancel", de: "Abbrechen")) {
                dismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            if viewModel.editorStep != .scope {
                Button(localizedAppText("Back", de: "Zurück")) {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.editorStep == .review {
                Button(localizedAppText("Save Rule", de: "Regel speichern")) {
                    viewModel.saveProfile()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(localizedAppText("Next", de: "Weiter")) {
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
            return localizedAppText(
                "App and website are optional. Leave both empty to create a global fallback rule.",
                de: "App und Website sind optional. Lass beides leer, um eine globale Fallback-Regel zu erstellen."
            )
        case .behavior:
            return localizedAppText("Define how TypeWhisper should respond in this context.", de: "Lege fest, wie TypeWhisper in diesem Kontext reagieren soll.")
        case .review:
            return localizedAppText("Review the name, matching, and advanced options before saving.", de: "Prüfe Name, Matching und fortgeschrittene Optionen vor dem Speichern.")
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
                Text(localizedAppText("Where should this rule apply?", de: "Wo gilt diese Regel?"))
                    .font(.title3.weight(.semibold))
                Text(localizedAppText(
                    "Apps and websites are optional. Combining both creates the most specific rule. Leave both empty for a global fallback.",
                    de: "Apps und Websites sind optional. Beides zusammen ergibt die spezifischste Regel. Lass beides leer für einen globalen Fallback."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            card(
                title: localizedAppText("Apps", de: "Apps"),
                description: localizedAppText("Choose the apps where this rule may apply automatically.", de: "Wähle die Apps, in denen diese Regel automatisch greifen darf."),
                icon: "square.stack.3d.up.fill",
                tint: .blue
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.editorBundleIdentifiers.isEmpty {
                        Text(localizedAppText("No apps selected.", de: "Keine Apps ausgewählt."))
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

                    Button(localizedAppText("Select Apps…", de: "Apps auswählen…")) {
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
            return localizedAppText("Limit website in \(appName)", de: "Website in \(appName) eingrenzen")
        }

        return localizedAppText("Optional: limit to a website", de: "Optional: auf eine Website eingrenzen")
    }

    private var websiteToggleDescription: String {
        if let detectedDomain = viewModel.editorDetectedDomain, viewModel.editorDetectedIsSupportedBrowser {
            return localizedAppText(
                "Currently detected: \(detectedDomain). This lets you limit the rule to a specific page or domain.",
                de: "Aktuell erkannt: \(detectedDomain). Die Regel kann damit auf eine konkrete Seite oder Domain begrenzt werden."
            )
        }

        if let appName = viewModel.editorRelevantBrowserName {
            return localizedAppText(
                "\(appName) is selected as the browser. Optionally add a domain here if the rule should not apply to every page.",
                de: "\(appName) ist als Browser gewählt. Ergänze hier optional eine Domain, wenn die Regel nicht für alle Seiten gelten soll."
            )
        }

        return localizedAppText(
            "Domains are only needed if the rule should apply to specific pages instead of the entire app.",
            de: "Domains sind nur nötig, wenn die Regel nicht für die ganze App, sondern nur für bestimmte Seiten gelten soll."
        )
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
                        Text(localizedAppText("Current Website", de: "Aktuelle Website"))
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
                        Button(localizedAppText("Use Domain", de: "Domain übernehmen")) {
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
                    Text(localizedAppText("No websites selected.", de: "Keine Websites ausgewählt."))
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
                    TextField(localizedAppText("e.g. github.com", de: "z. B. github.com"), text: $viewModel.urlPatternInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            viewModel.addUrlPattern()
                        }
                        .onChange(of: viewModel.urlPatternInput) {
                            viewModel.filterDomainSuggestions()
                        }

                    Button(localizedAppText("Add", de: "Hinzufügen")) {
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

                Text(localizedAppText(
                    "Subdomains are included automatically. `google.com` also matches `docs.google.com`.",
                    de: "Subdomains werden automatisch mit eingeschlossen. `google.com` matcht also auch `docs.google.com`."
                ))
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
                Text(localizedAppText("How should TypeWhisper respond?", de: "Wie soll TypeWhisper reagieren?"))
                    .font(.title3.weight(.semibold))
                Text(localizedAppText(
                    "Here you define language, prompt, engine, and output for this context. Priority and manual override come in the next step.",
                    de: "Hier legst du Sprache, Prompt, Engine und Ausgabe für diesen Kontext fest. Priorität und manuelle Übersteuerung folgen erst im nächsten Schritt."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            card(
                title: localizedAppText("Language & Transformation", de: "Sprache & Umwandlung"),
                description: localizedAppText("How spoken text is understood and optionally processed further.", de: "Wie gesprochener Text verstanden und optional weiterverarbeitet wird."),
                icon: "waveform.badge.mic",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: localizedAppText("Spoken Language", de: "Gesprochene Sprache"),
                        description: localizedAppText("Which language TypeWhisper should expect in this context.", de: "Welche Sprache TypeWhisper in diesem Kontext erwarten soll.")
                    ) {
                        Picker(localizedAppText("Spoken Language", de: "Gesprochene Sprache"), selection: $viewModel.editorInputLanguage) {
                            Text(localizedAppText("Global Setting", de: "Globale Einstellung")).tag(nil as String?)
                            Divider()
                            Text(localizedAppText("Auto-Detect", de: "Automatisch erkennen")).tag("auto" as String?)
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
                            title: localizedAppText("Translation", de: "Übersetzung"),
                            description: localizedAppText("Whether TypeWhisper should translate the text automatically before inserting it.", de: "Ob TypeWhisper den Text vor dem Einfügen automatisch übersetzen soll.")
                        ) {
                            Picker(localizedAppText("Translation", de: "Übersetzung"), selection: $viewModel.editorTranslationEnabled) {
                                Text(localizedAppText("Global Setting", de: "Globale Einstellung")).tag(nil as Bool?)
                                Divider()
                                Text(localizedAppText("On", de: "Ein")).tag(true as Bool?)
                                Text(localizedAppText("Off", de: "Aus")).tag(false as Bool?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if viewModel.editorTranslationEnabled != false {
                            Divider()

                            settingRow(
                                title: localizedAppText("Target Language", de: "Zielsprache"),
                                description: localizedAppText("Which language should be output after translation.", de: "Welche Sprache nach der Übersetzung ausgegeben werden soll.")
                            ) {
                                Picker(localizedAppText("Target Language", de: "Zielsprache"), selection: $viewModel.editorTranslationTargetLanguage) {
                                    Text(localizedAppText("Global Setting", de: "Globale Einstellung")).tag(nil as String?)
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
                        title: localizedAppText("Prompt", de: "Prompt"),
                        description: localizedAppText("Optional post-processing step for this rule.", de: "Optionaler Nachbearbeitungsschritt für diese Regel.")
                    ) {
                        Picker(localizedAppText("Prompt", de: "Prompt"), selection: $viewModel.editorPromptActionId) {
                            Text(localizedAppText("None", de: "Keiner")).tag(nil as String?)
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
                title: localizedAppText("Engine & Model", de: "Engine & Modell"),
                description: localizedAppText("Which engine should preferably handle this context.", de: "Welche Engine diesen Kontext bevorzugt behandeln soll."),
                icon: "cpu",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: localizedAppText("Transcription Engine", de: "Transkriptions-Engine"),
                        description: localizedAppText("Which engine TypeWhisper should prefer here.", de: "Welche Engine TypeWhisper hier bevorzugt verwenden soll.")
                    ) {
                        Picker(localizedAppText("Transcription Engine", de: "Transkriptions-Engine"), selection: $viewModel.editorEngineOverride) {
                            Text(localizedAppText("Global Setting", de: "Globale Einstellung")).tag(nil as String?)
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
                                title: localizedAppText("Model", de: "Modell"),
                                description: localizedAppText("Optional model within the selected engine.", de: "Optionales Modell innerhalb der gewählten Engine.")
                            ) {
                                Picker(localizedAppText("Model", de: "Modell"), selection: $viewModel.editorCloudModelOverride) {
                                    Text(localizedAppText("Default", de: "Standard")).tag(nil as String?)
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
                title: localizedAppText("Output", de: "Ausgabe"),
                description: localizedAppText("How the result should be inserted into the target context.", de: "Wie das Ergebnis im Zielkontext eingefügt werden soll."),
                icon: "text.badge.checkmark",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: localizedAppText("Output Format", de: "Ausgabeformat"),
                        description: localizedAppText("Which format the result should be inserted in.", de: "In welchem Format das Ergebnis eingefügt werden soll.")
                    ) {
                        Picker(localizedAppText("Output Format", de: "Ausgabeformat"), selection: $viewModel.editorOutputFormat) {
                            Text(localizedAppText("None", de: "Keins")).tag(nil as String?)
                            Divider()
                            Text(localizedAppText("Auto-Detect", de: "Automatisch erkennen")).tag("auto" as String?)
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
                        title: localizedAppText("Send After Inserting", de: "Senden nach dem Einfügen"),
                        description: localizedAppText("Presses Enter automatically after inserting when the target context expects it.", de: "Drückt nach dem Einfügen automatisch Enter, wenn der Zielkontext das erwartet.")
                    ) {
                        Toggle(localizedAppText("Press Enter Automatically", de: "Enter automatisch drücken"), isOn: $viewModel.editorAutoEnterEnabled)
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
                Text(localizedAppText("Review & Advanced", de: "Review & Erweitert"))
                    .font(.title3.weight(.semibold))
                Text(localizedAppText(
                    "First give the rule a name. After that you’ll see the preview, and everything else is optional.",
                    de: "Vergib zuerst einen Namen für die Regel. Danach siehst du die Vorschau, und alles Weitere ist optional."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            card(
                title: localizedAppText("Name", de: "Name"),
                description: localizedAppText("Optional: customize how this rule appears in the list.", de: "Optional: Passe an, wie diese Regel in der Liste angezeigt wird."),
                icon: "text.cursor",
                tint: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(
                        localizedAppText("Rule Name", de: "Regelname"),
                        text: Binding(
                            get: { viewModel.currentRuleName },
                            set: { viewModel.updateRuleName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Toggle(localizedAppText("Enable Rule", de: "Regel aktivieren"), isOn: $viewModel.editorIsEnabled)
                }
            }

            card(
                title: localizedAppText("Preview", de: "Vorschau"),
                description: localizedAppText("This is how the rule reads before saving.", de: "So liest sich die Regel vor dem Speichern."),
                icon: "sparkles",
                tint: .accentColor
            ) {
                RulePreviewCard(
                    title: localizedAppText("This Rule Does the Following", de: "Diese Regel macht Folgendes"),
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
                            Text(localizedAppText("Advanced Options", de: "Erweiterte Optionen"))
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(localizedAppText("Manual override, priority, memory, and more details.", de: "Manuelle Übersteuerung, Priorität, Memory und weitere Details."))
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
                            title: localizedAppText("Manual Override", de: "Manuelle Übersteuerung"),
                            description: localizedAppText("Optional: forces this rule regardless of the current context.", de: "Optional: erzwingt diese Regel unabhängig vom aktuellen Kontext."),
                            icon: "command",
                            tint: .accentColor
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                HotkeyRecorderView(
                                    label: viewModel.editorHotkeyLabel,
                                    title: localizedAppText("Manual Override", de: "Manuelle Übersteuerung"),
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
                                        localizedAppText(
                                            "This hotkey is also assigned to slot \(globalSlot.rawValue).",
                                            de: "Dieser Hotkey ist auch dem Slot \(globalSlot.rawValue) zugewiesen."
                                        ),
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
                            title: localizedAppText("Advanced Behavior", de: "Erweitertes Verhalten"),
                            description: localizedAppText("Only for power users. These options do not change the matching, only the behavior after a match.", de: "Nur für Power User. Diese Optionen ändern nicht das Matching, sondern das Verhalten nach dem Match."),
                            icon: "gearshape.2.fill",
                            tint: .teal
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Inline Commands", isOn: $viewModel.editorInlineCommandsEnabled)
                                Toggle("Memory", isOn: $viewModel.editorMemoryEnabled)

                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(localizedAppText("Order", de: "Reihenfolge"))
                                        Text(localizedAppText("Among equally specific rules, the one ranked higher wins.", de: "Zwischen gleich spezifischen Regeln gewinnt die höher einsortierte Regel."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(localizedAppText("Via Drag & Drop", de: "Per Drag & Drop"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                }

                                Text(localizedAppText("Change the order in the rules list via the drag handle.", de: "Die Reihenfolge änderst du in der Regeln-Liste über die Ziehen-Pille."))
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
                Text(localizedAppText("Select Apps", de: "Apps auswählen"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(localizedAppText("Search Apps…", de: "Apps durchsuchen…"), text: $viewModel.appSearchQuery)
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
                Button(localizedAppText("Done", de: "Fertig")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }
}
