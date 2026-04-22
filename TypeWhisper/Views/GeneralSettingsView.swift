import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    private enum AppVisibilityMode: String, CaseIterable {
        case menuBar
        case dock
        case dockWhileWindowOpen
    }

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var appLanguage: String = {
        if let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return lang
        }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden) private var dockIconBehaviorRawValue = DockIconBehavior.keepVisible.rawValue
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var settings = SettingsViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared

    private var supportsTranscriptPreview: Bool {
        dictation.indicatorStyle != .minimal
    }

    private var supportsPositionSelection: Bool {
        dictation.indicatorStyle == .overlay || dictation.indicatorStyle == .minimal
    }

    private var dockIconBehavior: DockIconBehavior {
        get { DockIconBehavior(rawValue: dockIconBehaviorRawValue) ?? .keepVisible }
        nonmutating set { dockIconBehaviorRawValue = newValue.rawValue }
    }

    private var appVisibilityMode: AppVisibilityMode {
        get {
            if showMenuBarIcon {
                return .menuBar
            }

            return dockIconBehavior == .keepVisible ? .dock : .dockWhileWindowOpen
        }
        nonmutating set {
            switch newValue {
            case .menuBar:
                showMenuBarIcon = true
                dockIconBehavior = .keepVisible
            case .dock:
                showMenuBarIcon = false
                dockIconBehavior = .keepVisible
            case .dockWhileWindowOpen:
                showMenuBarIcon = false
                dockIconBehavior = .onlyWhileWindowOpen
            }
        }
    }

    private var appVisibilityDescription: LocalizedStringKey {
        switch appVisibilityMode {
        case .menuBar:
            "TypeWhisper stays in the menu bar and hides its Dock icon while no window is open."
        case .dock:
            "TypeWhisper stays accessible via the Dock icon."
        case .dockWhileWindowOpen:
            "TypeWhisper hides both icons until a window opens. To reopen Settings later, launch TypeWhisper from Spotlight or the Applications folder."
        }
    }

    var body: some View {
        Form {
            Section(String(localized: "Spoken Language")) {
                LanguageSelectionEditor(
                    selection: $settings.languageSelection,
                    availableLanguages: settings.availableLanguages
                )

                Text(String(localized: "The language being spoken. Setting this explicitly improves accuracy."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if canImport(Translation)
            if #available(macOS 15, *) {
                Section(String(localized: "Translation")) {
                    Toggle(String(localized: "Enable translation"), isOn: $settings.translationEnabled)

                    if settings.translationEnabled {
                        Picker(String(localized: "Target language"), selection: $settings.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                    }

                    Text(String(localized: "Uses Apple Translate (on-device)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif

            Section(String(localized: "Language")) {
                Picker(String(localized: "App Language"), selection: $appLanguage) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Text(String(localized: "TypeWhisper will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Appearance")) {
                Picker(String(localized: "App visibility"), selection: Binding(
                    get: { appVisibilityMode },
                    set: { appVisibilityMode = $0 }
                )) {
                    Text(String(localized: "Menu bar icon")).tag(AppVisibilityMode.menuBar)
                    Text(String(localized: "Dock icon")).tag(AppVisibilityMode.dock)
                    Text(String(localized: "Dock icon only while a window is open")).tag(AppVisibilityMode.dockWhileWindowOpen)
                }

                Text(appVisibilityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Indicator")) {
                IndicatorPreviewView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                IndicatorStylePicker()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                if supportsTranscriptPreview {
                    Toggle(String(localized: "Show live transcript preview"), isOn: $dictation.indicatorTranscriptPreviewEnabled)

                    if !dictation.indicatorTranscriptPreviewEnabled {
                        Text(String(localized: "When disabled, TypeWhisper skips live transcript requests for the indicator and only runs the final transcription after you stop recording."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(String(localized: "Visibility"), selection: $dictation.notchIndicatorVisibility) {
                    Text(String(localized: "Always visible")).tag(NotchIndicatorVisibility.always)
                    Text(String(localized: "Only during activity")).tag(NotchIndicatorVisibility.duringActivity)
                    Text(String(localized: "Never")).tag(NotchIndicatorVisibility.never)
                }

                Picker(String(localized: "Display"), selection: $dictation.notchIndicatorDisplay) {
                    Text(String(localized: "Active Screen")).tag(NotchIndicatorDisplay.activeScreen)
                    Text(String(localized: "Primary Screen")).tag(NotchIndicatorDisplay.primaryScreen)
                    Text(String(localized: "Built-in Display")).tag(NotchIndicatorDisplay.builtInScreen)
                }

                if supportsPositionSelection {
                    Picker(String(localized: "Position"), selection: $dictation.overlayPosition) {
                        Text(String(localized: "Top")).tag(OverlayPosition.top)
                        Text(String(localized: "Bottom")).tag(OverlayPosition.bottom)
                    }
                }

                if dictation.indicatorStyle != .minimal {
                    Picker(String(localized: "Left Side"), selection: $dictation.notchIndicatorLeftContent) {
                        notchContentPickerOptions
                    }
                }

                Picker(String(localized: "Right Side"), selection: $dictation.notchIndicatorRightContent) {
                    notchContentPickerOptions
                }

                if dictation.indicatorStyle == .notch {
                    Text(String(localized: "The notch indicator extends the MacBook notch area to show recording status."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if dictation.indicatorStyle == .minimal {
                    Text(String(localized: "The indicator style is a compact power-user indicator that only shows status, errors, and action feedback."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "The overlay indicator appears as a floating pill on the screen."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                restartApp()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var notchContentPickerOptions: some View {
        Text(String(localized: "Recording Indicator")).tag(NotchIndicatorContent.indicator)
        Text(String(localized: "Timer")).tag(NotchIndicatorContent.timer)
        Text(String(localized: "Waveform")).tag(NotchIndicatorContent.waveform)
        Text(localizedAppText("Workflow", de: "Workflow")).tag(NotchIndicatorContent.profile)
        Text(String(localized: "None")).tag(NotchIndicatorContent.none)
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct LanguageSelectionEditor: View {
    private enum SelectionMode: Hashable {
        case inheritGlobal
        case auto
        case restricted
    }

    @Binding var selection: LanguageSelection
    let availableLanguages: [(code: String, name: String)]
    var nilBehavior: LanguageSelectionNilBehavior = .auto
    var inheritTitle: String? = nil
    var autoTitle: String = "Auto-detect all languages"
    var restrictedTitle: String = "Restrict detection to selected languages"

    @State private var isPickerPresented = false
    @State private var searchQuery = ""
    @State private var pendingRestrictedSelection = false

    private var mode: SelectionMode {
        if pendingRestrictedSelection {
            return .restricted
        }

        switch selection {
        case .inheritGlobal:
            return .inheritGlobal
        case .auto:
            return .auto
        case .exact, .hints:
            return .restricted
        }
    }

    private var filteredLanguages: [(code: String, name: String)] {
        guard !searchQuery.isEmpty else { return availableLanguages }
        return availableLanguages.filter {
            localizedAppLanguageSearchTerms(for: $0.code, preferredDisplayName: $0.name)
                .contains(where: { $0.localizedCaseInsensitiveContains(searchQuery) })
        }
    }

    private var featuredLanguages: [(code: String, name: String)] {
        let rankedLanguages: [(rank: Int, language: (code: String, name: String))] = filteredLanguages.compactMap { language in
                guard let rank = featuredAppLanguageRank(for: language.code) else { return nil }
                return (rank: rank, language: language)
            }
        return rankedLanguages.sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.language.name.localizedCaseInsensitiveCompare($1.language.name) == .orderedAscending
            }
            .map(\.language)
    }

    private var nonFeaturedLanguages: [(code: String, name: String)] {
        let featuredCodes = Set(featuredLanguages.map(\.code))
        return filteredLanguages.filter { !featuredCodes.contains($0.code) }
    }

    private var showsFeaturedSection: Bool {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !featuredLanguages.isEmpty
    }

    private var selectedCodes: [String] {
        selection.selectedCodes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inheritTitle {
                modeButton(
                    title: inheritTitle,
                    subtitle: "Use the global spoken language setting for this context.",
                    mode: .inheritGlobal
                )
            }

            modeButton(
                title: autoTitle,
                subtitle: "Let the engine detect the spoken language without restrictions.",
                mode: .auto
            )

            modeButton(
                title: restrictedTitle,
                subtitle: "Improve detection by limiting it to one or more expected languages.",
                mode: .restricted
            )

            if mode == .restricted {
                HStack(spacing: 8) {
                    Button {
                        isPickerPresented = true
                    } label: {
                        Label(selectedCodes.isEmpty ? "Select languages" : "Selected: \(selectedCodes.count)", systemImage: "plus.circle")
                    }
                    .buttonStyle(.bordered)
                }

                if selectedCodes.isEmpty {
                    Text("No languages selected yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 2) {
                        ForEach(selectedCodes, id: \.self) { code in
                            LanguageChip(
                                code: code,
                                title: localizedAppLanguageName(for: code),
                                removeAction: { removeCode(code) }
                            )
                        }
                    }
                }
            }
        }
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search languages", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if showsFeaturedSection {
                            ForEach(featuredLanguages, id: \.code) { language in
                                languageRow(language)
                            }

                            if !nonFeaturedLanguages.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                        }

                        ForEach(showsFeaturedSection ? nonFeaturedLanguages : filteredLanguages, id: \.code) { language in
                            languageRow(language)
                        }
                    }
                }
                .frame(width: 320, height: 240)
            }
            .padding(10)
        }
    }

    private func modeButton(title: String, subtitle: String, mode targetMode: SelectionMode) -> some View {
        Button {
            setMode(targetMode)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode == targetMode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(mode == targetMode ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func setMode(_ newMode: SelectionMode) {
        switch newMode {
        case .inheritGlobal:
            pendingRestrictedSelection = false
            selection = .inheritGlobal
        case .auto:
            pendingRestrictedSelection = false
            selection = .auto
        case .restricted:
            if selectedCodes.isEmpty {
                pendingRestrictedSelection = true
                isPickerPresented = true
            } else {
                pendingRestrictedSelection = false
                applySelection(for: selectedCodes)
            }
        }
    }

    private func toggleCode(_ code: String) {
        var codes = selectedCodes
        if let index = codes.firstIndex(of: code) {
            codes.remove(at: index)
        } else {
            codes.append(code)
        }
        applySelection(for: codes)
    }

    private func removeCode(_ code: String) {
        applySelection(for: selectedCodes.filter { $0 != code })
    }

    private func applySelection(for codes: [String]) {
        guard !codes.isEmpty else {
            pendingRestrictedSelection = true
            selection = .auto
            return
        }
        pendingRestrictedSelection = false
        selection = selection.withSelectedCodes(codes, nilBehavior: .auto)
    }

    private func languageRow(_ language: (code: String, name: String)) -> some View {
        let isSelected = selectedCodes.contains(language.code)

        return Button {
            toggleCode(language.code)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                LanguageLeadingVisual(code: language.code)
                Text(language.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(language.code.uppercased())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LanguageChip: View {
    let code: String
    let title: String
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            LanguageLeadingVisual(code: code)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button(action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct LanguageLeadingVisual: View {
    let code: String

    var body: some View {
        let flag = localizedAppLanguageFlag(for: code)
        let symbolText = flag ?? localizedAppLanguageBadgeText(for: code)
        let usesMonogram = flag == nil

        Text(symbolText)
            .font(usesMonogram ? .caption2.weight(.semibold) : .body)
            .foregroundStyle(usesMonogram ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 26, height: 16)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .accessibilityLabel(localizedAppLanguageName(for: code))
    }
}
