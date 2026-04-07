import AppKit
import SwiftUI
import TypeWhisperPluginSDK

@MainActor
final class PluginSettingsWindowManager {
    static let shared = PluginSettingsWindowManager()

    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: PluginSettingsWindowDelegate] = [:]

    func present(_ plugin: LoadedPlugin) {
        guard let settingsView = plugin.instance.settingsView else { return }

        if let window = windows[plugin.id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: settingsView
                .environment(\.pluginSettingsClose, { [weak window] in
                    window?.close()
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        hostingView.sizingOptions = []
        window.title = plugin.manifest.name
        window.contentMinSize = NSSize(width: 500, height: 400)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView

        let autosaveName = "plugin-settings.\(plugin.id)"
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        let delegate = PluginSettingsWindowDelegate(pluginId: plugin.id) { [weak self] pluginId in
            self?.windows[pluginId] = nil
            self?.delegates[pluginId] = nil
        }
        delegates[plugin.id] = delegate
        windows[plugin.id] = window
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class PluginSettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let pluginId: String
    private let onClose: (String) -> Void

    init(pluginId: String, onClose: @escaping (String) -> Void) {
        self.pluginId = pluginId
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose(pluginId)
    }
}

struct PluginSettingsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @State private var selectedTab = 0
    @State private var showUninstallAlert = false
    @State private var pluginToUninstall: LoadedPlugin?
    @State private var installFromFileError: String?
    @State private var hostingFilter: Int = 0 // 0=All, 1=Local, 2=Cloud
    @State private var expandedCategories: Set<String> = Set(PluginCategory.allCases.map(\.rawValue))

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

    private func categoryForPlugin(_ plugin: LoadedPlugin) -> PluginCategory {
        if let regPlugin = registryService.registry.first(where: { $0.id == plugin.id }) {
            return PluginCategory(rawValue: regPlugin.category) ?? .utility
        }
        if plugin.instance is TranscriptionEnginePlugin { return .transcription }
        if plugin.instance is LLMProviderPlugin { return .llm }
        if plugin.instance is PostProcessorPlugin { return .postProcessor }
        if plugin.instance is ActionPlugin { return .action }
        return .utility
    }

    private var groupedInstalledPlugins: [(category: PluginCategory, plugins: [LoadedPlugin])] {
        let grouped = Dictionary(grouping: pluginManager.loadedPlugins) { categoryForPlugin($0) }
        return grouped
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (category: $0.key, plugins: $0.value.sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }) }
    }

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
                ForEach(groupedInstalledPlugins, id: \.category) { group in
                    Section {
                        CategoryHeaderButton(
                            category: group.category,
                            count: group.plugins.count,
                            isExpanded: expandedCategories.contains(group.category.rawValue)
                        ) {
                            withAnimation {
                                if expandedCategories.contains(group.category.rawValue) {
                                    expandedCategories.remove(group.category.rawValue)
                                } else {
                                    expandedCategories.insert(group.category.rawValue)
                                }
                            }
                        }

                        if expandedCategories.contains(group.category.rawValue) {
                            ForEach(group.plugins) { plugin in
                                InstalledPluginRow(
                                    plugin: plugin,
                                    installInfo: registryService.installInfo(for: plugin.id),
                                    installState: registryService.installStates[plugin.id],
                                    registryPlugin: registryService.registry.first(where: { $0.id == plugin.id }),
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
                                .padding(.vertical, 4)
                            }
                        }
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

    private var filteredAvailablePlugins: [RegistryPlugin] {
        let available = registryService.registry.filter { registryPlugin in
            let info = registryService.installInfo(for: registryPlugin.id)
            if case .notInstalled = info { return true }
            return false
        }
        switch hostingFilter {
        case 1: return available.filter { $0.requiresAPIKey != true }
        case 2: return available.filter { $0.requiresAPIKey == true }
        default: return available
        }
    }

    private var groupedAvailablePlugins: [(category: PluginCategory, plugins: [RegistryPlugin])] {
        let grouped = Dictionary(grouping: filteredAvailablePlugins) { plugin in
            PluginCategory(rawValue: plugin.category) ?? .utility
        }
        return grouped
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (category: $0.key, plugins: $0.value.sorted {
                let d0 = $0.downloadCount ?? 0
                let d1 = $1.downloadCount ?? 0
                if d0 != d1 { return d0 > d1 }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }) }
    }

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
                Picker("", selection: $hostingFilter) {
                    Text(String(localized: "All")).tag(0)
                    Text(String(localized: "Local")).tag(1)
                    Text(String(localized: "Cloud")).tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if filteredAvailablePlugins.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Text(String(localized: "All available plugins are already installed."))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    }
                } else {
                    ForEach(groupedAvailablePlugins, id: \.category) { group in
                        Section {
                            CategoryHeaderButton(
                                category: group.category,
                                count: group.plugins.count,
                                isExpanded: expandedCategories.contains(group.category.rawValue)
                            ) {
                                withAnimation {
                                    if expandedCategories.contains(group.category.rawValue) {
                                        expandedCategories.remove(group.category.rawValue)
                                    } else {
                                        expandedCategories.insert(group.category.rawValue)
                                    }
                                }
                            }

                            if expandedCategories.contains(group.category.rawValue) {
                                ForEach(group.plugins) { plugin in
                                    AvailablePluginRow(
                                        plugin: plugin,
                                        installState: registryService.installStates[plugin.id],
                                        onInstall: {
                                            Task {
                                                await registryService.downloadAndInstall(plugin)
                                                PluginManager.shared.setPluginEnabled(plugin.id, enabled: true)
                                            }
                                        }
                                    )
                                    .padding(.vertical, 4)
                                }
                            }
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

// MARK: - Shared Components

private struct HostingBadge: View {
    let isCloud: Bool

    var body: some View {
        if isCloud {
            Text("Cloud")
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.cyan.opacity(0.15))
                .foregroundStyle(.cyan)
                .clipShape(Capsule())
        } else {
            Text(String(localized: "Local"))
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.green.opacity(0.15))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        }
    }
}

private struct CategoryHeaderButton: View {
    let category: PluginCategory
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Image(systemName: category.iconSystemName)
                    .foregroundStyle(.secondary)

                Text(category.displayName)
                    .font(.headline)

                Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.15))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(category.displayName), \(count) plugins"))
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
    }
}

// MARK: - Installed Plugin Row

private struct InstalledPluginRow: View {
    let plugin: LoadedPlugin
    let installInfo: PluginInstallInfo
    let installState: PluginRegistryService.InstallState?
    let registryPlugin: RegistryPlugin?
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    @State private var pluginActivity: PluginSettingsActivity?

    private let activityTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var isCloud: Bool {
        registryPlugin?.requiresAPIKey == true || plugin.manifest.requiresAPIKey == true
    }

    var body: some View {
        HStack {
            Image(systemName: registryPlugin?.iconSystemName ?? plugin.manifest.iconSystemName ?? "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.blue)
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
                    if !plugin.isBundled {
                        HostingBadge(isCloud: isCloud)
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Downloading \(plugin.manifest.name)"))
                    .accessibilityValue("\(Int(progress * 100))%")
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
                }
            } else if case .updateAvailable = installInfo {
                Button(String(localized: "Update")) {
                    onUpdate()
                }
                .controlSize(.small)
            } else if let pluginActivity {
                PluginSettingsActivityView(activity: pluginActivity)
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
                .accessibilityLabel(String(localized: "Uninstall \(plugin.manifest.name)"))
            }

            if plugin.instance.settingsView != nil {
                Button {
                    PluginSettingsWindowManager.shared.present(plugin)
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Settings for \(plugin.manifest.name)"))
            }

            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { enabled in
                    PluginManager.shared.setPluginEnabled(plugin.id, enabled: enabled)
                }
            ))
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(plugin.manifest.name)"))
        }
        .onAppear {
            refreshPluginActivity()
        }
        .onReceive(activityTimer) { _ in
            refreshPluginActivity()
        }
    }

    private func refreshPluginActivity() {
        pluginActivity = (plugin.instance as? any PluginSettingsActivityReporting)?.currentSettingsActivity
    }
}

// MARK: - Available Plugin Row

struct AvailablePluginRow: View {
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
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.headline)
                    HostingBadge(isCloud: plugin.requiresAPIKey == true)
                }
                Text(plugin.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("v\(plugin.version)")
                    Text(plugin.author)
                    Text(PluginRegistryService.formattedSize(plugin.size))
                    if let count = plugin.downloadCount, count > 0 {
                        Label(
                            String(localized: "\(PluginRegistryService.formattedDownloadCount(count)) downloads"),
                            systemImage: "arrow.down.circle"
                        )
                    }
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Downloading \(plugin.name)"))
                    .accessibilityValue("\(Int(progress * 100))%")
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
                .accessibilityLabel(String(localized: "Install \(plugin.name)"))
            }
        }
    }
}

private struct PluginSettingsActivityView: View {
    let activity: PluginSettingsActivity

    var body: some View {
        if let progress = activity.progress {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                if activity.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(activity.message)
                    .font(.caption)
                    .foregroundStyle(activity.isError ? .red : .secondary)
                    .lineLimit(1)
            }
        }
    }
}
