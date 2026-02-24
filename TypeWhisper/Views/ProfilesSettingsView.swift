import SwiftUI

struct ProfilesSettingsView: View {
    @ObservedObject private var viewModel = ProfilesViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(String(localized: "Profiles"))
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.prepareNewProfile()
                } label: {
                    Label(String(localized: "Add Profile"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(.bar)

            Divider()

            if viewModel.profiles.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Profiles"), systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text(String(localized: "Create profiles to use app-specific transcription settings."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.profiles, id: \.id) { profile in
                        ProfileRow(profile: profile, viewModel: viewModel)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .sheet(isPresented: $viewModel.showingEditor) {
            ProfileEditorSheet(viewModel: viewModel)
        }
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    let profile: Profile
    @ObservedObject var viewModel: ProfilesViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))

                let subtitle = viewModel.profileSubtitle(profile)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { profile.isEnabled },
                set: { _ in viewModel.toggleProfile(profile) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            Button {
                viewModel.prepareEditProfile(profile)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                viewModel.deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.prepareEditProfile(profile)
        }
    }
}

// MARK: - Editor Sheet

private struct ProfileEditorSheet: View {
    @ObservedObject var viewModel: ProfilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(viewModel.editingProfile == nil
                     ? String(localized: "New Profile")
                     : String(localized: "Edit Profile"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Profile name"), text: $viewModel.editorName)
                }

                Section(String(localized: "Hotkey")) {
                    HotkeyRecorderView(
                        label: viewModel.editorHotkeyLabel,
                        title: String(localized: "Profile shortcut"),
                        onRecord: { hotkey in
                            // Check profile-vs-profile conflict
                            if let conflictId = ServiceContainer.shared.hotkeyService.isHotkeyAssignedToProfile(
                                hotkey, excludingProfileId: viewModel.editingProfile?.id
                            ) {
                                // Auto-clear the other profile's hotkey
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

                    // Warn if conflicts with global slot
                    if let hotkey = viewModel.editorHotkey,
                       let globalSlot = ServiceContainer.shared.hotkeyService.isHotkeyAssignedToGlobalSlot(hotkey) {
                        Label(
                            String(localized: "This hotkey is also assigned to the \(globalSlot.rawValue) slot."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    }

                    Text(String(localized: "Assign a hotkey to always use this profile, regardless of the active app."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Apps")) {
                    if viewModel.editorBundleIdentifiers.isEmpty {
                        Text(String(localized: "No apps assigned"))
                            .foregroundStyle(.secondary)
                            .font(.caption)
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
                        }
                    }

                    Button(String(localized: "Choose Apps...")) {
                        viewModel.appSearchQuery = ""
                        viewModel.showingAppPicker = true
                    }
                }

                #if !APPSTORE
                Section(String(localized: "URL Patterns")) {
                    if viewModel.editorUrlPatterns.isEmpty {
                        Text(String(localized: "No URL patterns"))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(viewModel.editorUrlPatterns, id: \.self) { pattern in
                            HStack {
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
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
                        .disabled(viewModel.urlPatternInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !viewModel.domainSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.domainSuggestions, id: \.self) { domain in
                                Button {
                                    viewModel.selectDomainSuggestion(domain)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "globe")
                                            .font(.caption)
                                        Text(domain)
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                            }
                        }
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text(String(localized: "Subdomains are included automatically. E.g. \"google.com\" also matches \"docs.google.com\"."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                Section(String(localized: "Overrides")) {
                    // Input language override
                    Picker(String(localized: "Spoken language"), selection: $viewModel.editorInputLanguage) {
                        Text(String(localized: "Global Setting")).tag(nil as String?)
                        Divider()
                        Text(String(localized: "Auto-detect")).tag("auto" as String?)
                        Divider()
                        ForEach(viewModel.settingsViewModel.availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code as String?)
                        }
                    }

                    // Translation target language override
                    Picker(String(localized: "Target language"), selection: $viewModel.editorTranslationTargetLanguage) {
                        Text(String(localized: "Global Setting")).tag(nil as String?)
                        Divider()
                        ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code as String?)
                        }
                    }

                    // Engine override
                    Picker(String(localized: "Engine"), selection: $viewModel.editorEngineOverride) {
                        Text(String(localized: "Global Setting")).tag(nil as String?)
                        Divider()
                        ForEach(EngineType.availableCases) { engine in
                            Text(engine.displayName).tag(engine.rawValue as String?)
                        }

                        let configuredPlugins = ModelManagerViewModel.shared.configuredPluginEngines
                        if !configuredPlugins.isEmpty {
                            Divider()
                            ForEach(configuredPlugins, id: \.providerId) { plugin in
                                Text(plugin.providerDisplayName).tag(plugin.providerId as String?)
                            }
                        }
                    }

                    if let override = viewModel.editorEngineOverride {
                        if EngineType(rawValue: override) != nil {
                            Text(String(localized: "Using a different engine per profile requires both models to be loaded, which increases memory usage."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let plugin = PluginManager.shared.transcriptionEngine(for: override) {
                            let models = plugin.transcriptionModels
                            if models.count > 1 {
                                Picker(String(localized: "Model"), selection: $viewModel.editorCloudModelOverride) {
                                    Text(String(localized: "Default")).tag(nil as String?)
                                    Divider()
                                    ForEach(models, id: \.id) { model in
                                        Text(model.displayName).tag(model.id as String?)
                                    }
                                }
                            }

                            Text(String(localized: "Cloud transcription requires an internet connection."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Whisper mode override
                    Picker(String(localized: "Whisper Mode"), selection: $viewModel.editorWhisperModeOverride) {
                        Text(String(localized: "Global Setting")).tag(nil as Bool?)
                        Divider()
                        Text(String(localized: "On")).tag(true as Bool?)
                        Text(String(localized: "Off")).tag(false as Bool?)
                    }

                    // Prompt action override
                    Picker(String(localized: "Prompt"), selection: $viewModel.editorPromptActionId) {
                        Text(String(localized: "None")).tag(nil as String?)
                        Divider()
                        ForEach(PromptActionsViewModel.shared.promptActions.filter(\.isEnabled)) { action in
                            Label(action.name, systemImage: action.icon).tag(action.id.uuidString as String?)
                        }
                    }

                    Text(String(localized: "When a prompt is assigned, dictated text will be processed by the LLM before insertion. This replaces translation."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(String(localized: "Auto-Submit"), selection: $viewModel.editorAutoSubmitEnabled) {
                        Text(String(localized: "Off")).tag(nil as Bool?)
                        Divider()
                        Text(String(localized: "On")).tag(true as Bool?)
                    }
                }

                Section(String(localized: "Priority")) {
                    Stepper(value: $viewModel.editorPriority, in: 0...100) {
                        HStack {
                            Text(String(localized: "Priority"))
                            Spacer()
                            Text("\(viewModel.editorPriority)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(String(localized: "Higher priority profiles take precedence when multiple profiles match."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer buttons
            HStack {
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Save")) {
                    viewModel.saveProfile()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.editorName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 720)
        .sheet(isPresented: $viewModel.showingAppPicker) {
            AppPickerSheet(viewModel: viewModel)
        }
    }
}

// MARK: - App Picker Sheet

private struct AppPickerSheet: View {
    @ObservedObject var viewModel: ProfilesViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Choose Apps"))
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search apps..."), text: $viewModel.appSearchQuery)
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
