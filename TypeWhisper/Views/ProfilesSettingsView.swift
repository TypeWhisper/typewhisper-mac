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

                    if viewModel.isFilteringRulesByPrompt {
                        PromptRuleFilterBanner(viewModel: viewModel)
                    }

                    if viewModel.profiles.isEmpty {
                        emptyState
                    } else if viewModel.visibleProfiles.isEmpty {
                        filteredEmptyState
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
                Text(String(localized: "Rules"))
                    .font(.headline)
                Text(String(localized: "When context X is detected, TypeWhisper uses behavior Y."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.prepareNewProfile()
            } label: {
                Label(String(localized: "New Rule"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(16)
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Rules Yet"), systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Rules tell TypeWhisper which language, engine, or output format should apply in which context."))
                Text(String(localized: "Examples: Slack -> English with Auto Enter, github.com -> code prompt, Mail -> German with translation."))
            }
            .frame(maxWidth: 420, alignment: .leading)
        } actions: {
            Button(String(localized: "Create First Rule")) {
                viewModel.prepareNewProfile()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background {
            groupedListSurface(cornerRadius: 16)
        }
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Matching Rules"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(String(localized: "No rules currently use the selected prompt."))
        } actions: {
            Button(String(localized: "Show All Rules")) {
                viewModel.clearPromptRuleFocus()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background {
            groupedListSurface(cornerRadius: 16)
        }
    }

    private var rulesList: some View {
        let indexedProfiles = Array(viewModel.visibleProfiles.enumerated())

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
            Text(String(localized: "Active Rule"))
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

private struct PromptRuleFilterBanner: View {
    @ObservedObject var viewModel: ProfilesViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Showing rules linked to this prompt."))
                    .font(.subheadline.weight(.semibold))

                if let promptAction = viewModel.focusedPromptAction {
                    RulePromptChip(action: promptAction)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if let promptAction = viewModel.focusedPromptAction {
                    Button(String(localized: "Open Prompt")) {
                        viewModel.editPrompt(promptActionId: promptAction.id.uuidString)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(String(localized: "Show All")) {
                    viewModel.clearPromptRuleFocus()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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

                    if let promptAction = viewModel.promptAction(for: profile) {
                        Button {
                            viewModel.editPrompt(for: profile)
                        } label: {
                            RulePromptChip(action: promptAction)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Open prompt"))
                    }
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
        .alert(String(localized: "Delete rule?"), isPresented: $showingDeleteConfirmation) {
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteProfile(profile)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Do you really want to delete “\(profile.name)”?"))
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
            .help(String(localized: "Change order via drag and drop"))
    }
}

private struct RulePromptChip: View {
    let action: PromptAction

    var body: some View {
        Label(
            String(localized: "Prompt: \(action.name)"),
            systemImage: action.icon
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
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
                        ? String(localized: "Rule Wizard")
                        : String(localized: "Adjust Rule"),
                    tint: .accentColor
                )

                Text(
                    viewModel.editingProfile == nil
                        ? String(localized: "New Rule")
                        : String(localized: "Edit Rule")
                )
                .font(.title2.weight(.semibold))

                Text(String(localized: "From context to behavior in three clear steps."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                infoChip(
                    String(localized: "Step \(currentStepNumber) of \(totalSteps)"),
                    tint: .orange
                )

                if viewModel.editorStep == .review {
                    Toggle(String(localized: "Active"), isOn: $viewModel.editorIsEnabled)
                        .toggleStyle(.switch)
                }
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Step \(currentStepNumber) of \(totalSteps)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(stepGuidance)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            if viewModel.editorStep != .scope {
                Button(String(localized: "Back")) {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.editorStep == .review {
                Button(String(localized: "Save Rule")) {
                    viewModel.saveProfile()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "Next")) {
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
            return String(localized: "App and website are optional. Leave both empty to create a global fallback rule.")
        case .behavior:
            return String(localized: "Define how TypeWhisper should respond in this context.")
        case .review:
            return String(localized: "Review the name, matching, and advanced options before saving.")
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
                Text(String(localized: "Where should this rule apply?"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Apps and websites are optional. Combining both creates the most specific rule. Leave both empty for a global fallback."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if viewModel.shouldShowPrefilledPromptFallbackNotice {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.orange.opacity(0.16))
                            .frame(width: 36, height: 36)

                        Image(systemName: "sparkles")
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Prompt already selected"))
                            .font(.subheadline.weight(.semibold))
                        Text(String(localized: "Saving without an app or website creates a global fallback rule with this prompt."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(16)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                }
            }

            card(
                title: String(localized: "Apps"),
                description: String(localized: "Choose the apps where this rule may apply automatically."),
                icon: "square.stack.3d.up.fill",
                tint: .blue
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.editorBundleIdentifiers.isEmpty {
                        Text(String(localized: "No apps selected."))
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

                    Button(String(localized: "Select Apps…")) {
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
            return String(localized: "Limit website in \(appName)")
        }

        return String(localized: "Optional: limit to a website")
    }

    private var websiteToggleDescription: String {
        if let detectedDomain = viewModel.editorDetectedDomain, viewModel.editorDetectedIsSupportedBrowser {
            return String(localized: "Currently detected: \(detectedDomain). This lets you limit the rule to a specific page or domain.")
        }

        if let appName = viewModel.editorRelevantBrowserName {
            return String(localized: "\(appName) is selected as the browser. Optionally add a domain here if the rule should not apply to every page.")
        }

        return String(localized: "Domains are only needed if the rule should apply to specific pages instead of the entire app.")
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
                        Text(String(localized: "Current Website"))
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
                        Button(String(localized: "Use Domain")) {
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
                    Text(String(localized: "No websites selected."))
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
                    TextField(String(localized: "e.g. github.com"), text: $viewModel.urlPatternInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            viewModel.addUrlPattern()
                        }
                        .onChange(of: viewModel.urlPatternInput) {
                            viewModel.filterDomainSuggestions()
                        }

                    Button(String(localized: "Add")) {
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

                Text(String(localized: "Subdomains are included automatically. `google.com` also matches `docs.google.com`."))
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
                Text(String(localized: "How should TypeWhisper respond?"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "Here you define language, prompt, engine, and output for this context. Priority and manual override come in the next step."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            card(
                title: String(localized: "Language & Transformation"),
                description: String(localized: "How spoken text is understood and optionally processed further."),
                icon: "waveform.badge.mic",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: String(localized: "Spoken Language"),
                        description: String(localized: "Which language TypeWhisper should expect in this context.")
                    ) {
                        LanguageSelectionEditor(
                            selection: Binding(
                                get: {
                                    LanguageSelection(
                                        storedValue: viewModel.editorInputLanguage,
                                        nilBehavior: .inheritGlobal
                                    )
                                },
                                set: { viewModel.editorInputLanguage = $0.storedValue(nilBehavior: .inheritGlobal) }
                            ),
                            availableLanguages: viewModel.settingsViewModel.availableLanguages,
                            nilBehavior: .inheritGlobal,
                            inheritTitle: String(localized: "Global Setting")
                        )
                    }

                    #if canImport(Translation)
                    if #available(macOS 15, *) {
                        Divider()

                        settingRow(
                            title: String(localized: "Translation"),
                            description: String(localized: "Whether TypeWhisper should translate the text automatically before inserting it.")
                        ) {
                            Picker(String(localized: "Translation"), selection: $viewModel.editorTranslationEnabled) {
                                Text(String(localized: "Global Setting")).tag(nil as Bool?)
                                Divider()
                                Text(String(localized: "On")).tag(true as Bool?)
                                Text(String(localized: "Off")).tag(false as Bool?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

                        if viewModel.editorTranslationEnabled != false {
                            Divider()

                            settingRow(
                                title: String(localized: "Target Language"),
                                description: String(localized: "Which language should be output after translation.")
                            ) {
                                Picker(String(localized: "Target Language"), selection: $viewModel.editorTranslationTargetLanguage) {
                                    Text(String(localized: "Global Setting")).tag(nil as String?)
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
                        title: String(localized: "Prompt"),
                        description: String(localized: "Optional post-processing step for this rule.")
                    ) {
                        HStack(spacing: 10) {
                            Picker(String(localized: "Prompt"), selection: $viewModel.editorPromptActionId) {
                                Text(String(localized: "None")).tag(nil as String?)
                                Divider()
                                ForEach(PromptActionsViewModel.shared.promptActions.filter(\.isEnabled)) { action in
                                    Label(action.name, systemImage: action.icon).tag(action.id.uuidString as String?)
                                }
                            }

                            if let editorPromptAction = viewModel.editorPromptAction {
                                Button(String(localized: "Edit Prompt")) {
                                    viewModel.editPrompt(promptActionId: editorPromptAction.id.uuidString)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            card(
                title: String(localized: "Engine & Model"),
                description: String(localized: "Which engine should preferably handle this context."),
                icon: "cpu",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: String(localized: "Transcription Engine"),
                        description: String(localized: "Which engine TypeWhisper should prefer here.")
                    ) {
                        Picker(String(localized: "Transcription Engine"), selection: $viewModel.editorEngineOverride) {
                            Text(String(localized: "Global Setting")).tag(nil as String?)
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
                                title: String(localized: "Model"),
                                description: String(localized: "Optional model within the selected engine.")
                            ) {
                                Picker(String(localized: "Model"), selection: $viewModel.editorCloudModelOverride) {
                                    Text(String(localized: "Default")).tag(nil as String?)
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
                title: String(localized: "Output"),
                description: String(localized: "How the result should be inserted into the target context."),
                icon: "text.badge.checkmark",
                tint: .accentColor
            ) {
                VStack(spacing: 0) {
                    settingRow(
                        title: String(localized: "Output Format"),
                        description: String(localized: "Which format the result should be inserted in.")
                    ) {
                        Picker(String(localized: "Output Format"), selection: $viewModel.editorOutputFormat) {
                            Text(String(localized: "None")).tag(nil as String?)
                            Divider()
                            Text(String(localized: "Auto-Detect")).tag("auto" as String?)
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
                        title: String(localized: "Send After Inserting"),
                        description: String(localized: "Presses Enter automatically after inserting when the target context expects it.")
                    ) {
                        Toggle(String(localized: "Press Enter Automatically"), isOn: $viewModel.editorAutoEnterEnabled)
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
                Text(String(localized: "Review & Advanced"))
                    .font(.title3.weight(.semibold))
                Text(String(localized: "First give the rule a name. After that you’ll see the preview, and everything else is optional."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            card(
                title: String(localized: "Name"),
                description: String(localized: "Optional: customize how this rule appears in the list."),
                icon: "text.cursor",
                tint: .accentColor
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(
                        String(localized: "Rule Name"),
                        text: Binding(
                            get: { viewModel.currentRuleName },
                            set: { viewModel.updateRuleName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Toggle(String(localized: "Enable Rule"), isOn: $viewModel.editorIsEnabled)
                }
            }

            card(
                title: String(localized: "Preview"),
                description: String(localized: "This is how the rule reads before saving."),
                icon: "sparkles",
                tint: .accentColor
            ) {
                RulePreviewCard(
                    title: String(localized: "This Rule Does the Following"),
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
                            Text(String(localized: "Advanced Options"))
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(String(localized: "Manual override, priority, memory, and more details."))
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
                            title: String(localized: "Manual Override"),
                            description: String(localized: "Optional: forces this rule regardless of the current context."),
                            icon: "command",
                            tint: .accentColor
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                HotkeyRecorderView(
                                    label: viewModel.editorHotkeyLabel,
                                    title: String(localized: "Manual Override"),
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
                                        String(localized: "This hotkey is also assigned to slot \(globalSlot.rawValue)."),
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
                            title: String(localized: "Advanced Behavior"),
                            description: String(localized: "Only for power users. These options do not change the matching, only the behavior after a match."),
                            icon: "gearshape.2.fill",
                            tint: .teal
                        ) {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle("Inline Commands", isOn: $viewModel.editorInlineCommandsEnabled)
                                Toggle("Memory", isOn: $viewModel.editorMemoryEnabled)

                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(localized: "Order"))
                                        Text(String(localized: "Among equally specific rules, the one ranked higher wins."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(String(localized: "Via Drag & Drop"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                }

                                Text(String(localized: "Change the order in the rules list via the drag handle."))
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
                Text(String(localized: "Select Apps"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search Apps…"), text: $viewModel.appSearchQuery)
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
                Button(String(localized: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }
}
