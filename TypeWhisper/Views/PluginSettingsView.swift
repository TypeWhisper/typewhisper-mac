import SwiftUI

struct PluginSettingsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @State private var selectedTab = 0
    @State private var showUninstallAlert = false
    @State private var pluginToUninstall: LoadedPlugin?
    @State private var installFromFileError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(String(localized: "Installed")).tag(0)
                Text(String(localized: "Available")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if selectedTab == 0 {
                installedTab
            } else {
                availableTab
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .alert(String(localized: "Uninstall Plugin"), isPresented: $showUninstallAlert, presenting: pluginToUninstall) { plugin in
            Button(String(localized: "Uninstall"), role: .destructive) {
                registryService.uninstallPlugin(plugin.id, deleteData: true)
                pluginToUninstall = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pluginToUninstall = nil
            }
        } message: { plugin in
            Text(String(localized: "Are you sure you want to uninstall \(plugin.manifest.name)? This will remove the plugin and its data."))
        }
        .alert(String(localized: "Install Failed"), isPresented: .init(
            get: { installFromFileError != nil },
            set: { if !$0 { installFromFileError = nil } }
        )) {
            Button(String(localized: "OK")) { installFromFileError = nil }
        } message: {
            if let error = installFromFileError {
                Text(error)
            }
        }
    }

    // MARK: - Installed Tab

    private var installedTab: some View {
        Form {
            if pluginManager.loadedPlugins.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text(String(localized: "No plugins installed."))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "Browse the Available tab or install from file."))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
            } else {
                Section(String(localized: "Plugins")) {
                    ForEach(pluginManager.loadedPlugins) { plugin in
                        InstalledPluginRow(
                            plugin: plugin,
                            installInfo: registryService.installInfo(for: plugin.id),
                            onUpdate: {
                                if let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id }) {
                                    Task { await registryService.downloadAndInstall(registryPlugin) }
                                }
                            },
                            onUninstall: {
                                pluginToUninstall = plugin
                                showUninstallAlert = true
                            }
                        )
                    }
                }
            }

            Section {
                HStack {
                    Button(String(localized: "Open Plugins Folder")) {
                        pluginManager.openPluginsFolder()
                    }
                    Spacer()
                    Button(String(localized: "Install from File...")) {
                        installFromFile()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .task {
            await registryService.fetchRegistry()
        }
    }

    // MARK: - Available Tab

    private var availableTab: some View {
        Form {
            switch registryService.fetchState {
            case .idle, .loading:
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                }
            case .error(let message):
                Section {
                    VStack(spacing: 8) {
                        Text(String(localized: "Failed to load plugins."))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(String(localized: "Retry")) {
                            Task { await registryService.fetchRegistry() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
            case .loaded:
                let availablePlugins = registryService.registry.filter { registryPlugin in
                    let info = registryService.installInfo(for: registryPlugin.id)
                    if case .notInstalled = info { return true }
                    return false
                }

                if availablePlugins.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Text(String(localized: "All available plugins are already installed."))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    }
                } else {
                    Section(String(localized: "Available Plugins")) {
                        ForEach(availablePlugins) { plugin in
                            AvailablePluginRow(
                                plugin: plugin,
                                installState: registryService.installStates[plugin.id],
                                onInstall: {
                                    Task { await registryService.downloadAndInstall(plugin) }
                                }
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .task {
            await registryService.fetchRegistry()
        }
    }

    // MARK: - Install from File

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.bundle, .zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Select a plugin bundle or ZIP file to install.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await registryService.installFromFile(url)
            } catch {
                installFromFileError = error.localizedDescription
            }
        }
    }
}

// MARK: - Installed Plugin Row

private struct InstalledPluginRow: View {
    let plugin: LoadedPlugin
    let installInfo: PluginInstallInfo
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    @State private var showSettings = false

    var body: some View {
        HStack {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                    if case .updateAvailable = installInfo {
                        Text(String(localized: "Update"))
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if plugin.isBundled {
                        Text(String(localized: "Built-in"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text("v\(plugin.manifest.version)")
                    if let author = plugin.manifest.author {
                        Text(author)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if case .updateAvailable = installInfo {
                Button(String(localized: "Update")) {
                    onUpdate()
                }
                .controlSize(.small)
            }

            if !plugin.isBundled {
                Button {
                    onUninstall()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Uninstall"))
            }

            if plugin.instance.settingsView != nil {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }

            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { enabled in
                    PluginManager.shared.setPluginEnabled(plugin.id, enabled: enabled)
                }
            ))
            .labelsHidden()
        }
        .sheet(isPresented: $showSettings) {
            if let view = plugin.instance.settingsView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(plugin.manifest.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            showSettings = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()

                    Divider()

                    view
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 500, minHeight: 400)
            }
        }
    }
}

// MARK: - Available Plugin Row

private struct AvailablePluginRow: View {
    let plugin: RegistryPlugin
    let installState: PluginRegistryService.InstallState?
    let onInstall: () -> Void

    var body: some View {
        HStack {
            Image(systemName: plugin.iconSystemName ?? "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.headline)
                Text(plugin.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("v\(plugin.version)")
                    Text(plugin.author)
                    Text(PluginRegistryService.formattedSize(plugin.size))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if let state = installState {
                switch state {
                case .downloading(let progress):
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .frame(width: 80)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                case .extracting:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "Installing..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .error(let message):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Button(String(localized: "Retry")) {
                        onInstall()
                    }
                    .controlSize(.small)
                }
            } else {
                Button(String(localized: "Install")) {
                    onInstall()
                }
                .controlSize(.small)
            }
        }
    }
}
