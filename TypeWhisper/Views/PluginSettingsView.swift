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

private enum IntegrationTab: String, CaseIterable {
    case installed
    case discover
    case manual

    var title: String {
        switch self {
        case .installed:
            return String(localized: "Installed")
        case .discover:
            return String(localized: "Discover")
        case .manual:
            return String(localized: "Manual")
        }
    }
}

private enum IntegrationPluginSource: Equatable {
    case builtIn
    case official
    case community
    case manual

    var title: String {
        switch self {
        case .builtIn:
            return String(localized: "Built-in")
        case .official:
            return String(localized: "Marketplace")
        case .community:
            return String(localized: "Community")
        case .manual:
            return String(localized: "Manual")
        }
    }

    var systemImage: String {
        switch self {
        case .builtIn:
            return "checkmark.seal"
        case .official:
            return "sparkles"
        case .community:
            return "person.2"
        case .manual:
            return "folder.badge.plus"
        }
    }

    var tint: Color {
        switch self {
        case .builtIn:
            return .blue
        case .official:
            return .indigo
        case .community:
            return .purple
        case .manual:
            return .orange
        }
    }
}

struct PluginSettingsView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @State private var selectedTab: IntegrationTab = .installed
    @State private var showUninstallAlert = false
    @State private var pluginToUninstall: LoadedPlugin?
    @State private var pendingBoundaryUpgradePlugin: RegistryPlugin?
    @State private var pendingBoundaryUpgradeNotice: ExternalBundleNotice?
    @State private var installFromFileError: String?
    @State private var includeCommunityPlugins = true
    @State private var selectedCapabilityFilters: Set<PluginCategory> = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            integrationsHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        Picker("", selection: $selectedTab) {
                            ForEach(IntegrationTab.allCases, id: \.self) { tab in
                                Text(tab.title).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 360)

                        Spacer()

                        HostingSummaryInline(localCount: localPluginCount, cloudCount: cloudPluginCount)
                    }

                    switch selectedTab {
                    case .installed:
                        installedTab
                    case .discover:
                        availableTab
                    case .manual:
                        manualTab
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: selectedTab) { _, _ in
            normalizeDiscoverState()
        }
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
        .alert(
            String(localized: "Replace Legacy Plugin Bundle"),
            isPresented: .init(
                get: { pendingBoundaryUpgradePlugin != nil },
                set: {
                    if !$0 {
                        pendingBoundaryUpgradePlugin = nil
                        pendingBoundaryUpgradeNotice = nil
                    }
                }
            ),
            presenting: pendingBoundaryUpgradePlugin
        ) { plugin in
            Button(String(localized: "Replace"), role: .destructive) {
                pendingBoundaryUpgradePlugin = nil
                pendingBoundaryUpgradeNotice = nil
                Task {
                    await registryService.downloadAndInstall(plugin)
                    PluginManager.shared.setPluginEnabled(plugin.id, enabled: true)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingBoundaryUpgradePlugin = nil
                pendingBoundaryUpgradeNotice = nil
            }
        } message: { plugin in
            Text(boundaryUpgradeMessage(for: plugin, notice: pendingBoundaryUpgradeNotice))
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

    // MARK: - Header

    private var integrationsHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Integrations"))
                    .font(.title3.weight(.semibold))
                Text(integrationSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                pluginManager.openPluginsFolder()
            } label: {
                Image(systemName: "folder")
            }
            .help(String(localized: "Open Plugins Folder"))

            Button {
                installFromFile()
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "Install from File..."))
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(.bar)
    }

    private var integrationSummaryText: String {
        let installed = pluginManager.loadedPlugins.count
        let updates = registryService.availableUpdatesCount
        let available = availablePlugins.count
        if updates > 0 {
            return String(localized: "\(installed) installed • \(updates) updates • \(available) available")
        }
        return String(localized: "\(installed) installed • \(available) available")
    }

    private func normalizeDiscoverState() {
        if selectedTab != .discover {
            searchText = ""
            selectedCapabilityFilters.removeAll()
        }
    }

    // MARK: - Installed Tab

    private func categoriesForPlugin(_ plugin: LoadedPlugin, registryPlugin: RegistryPlugin?) -> [PluginCategory] {
        let declaredCategories = categories(
            from: registryPlugin?.categories ?? plugin.manifest.resolvedCategoryIdentifiers
        )
        let inferredCategories = inferredCategories(for: plugin)

        return displayCategories(declaredCategories + inferredCategories)
    }

    private func categories(from identifiers: [String]) -> [PluginCategory] {
        identifiers.compactMap(PluginCategory.init(rawValue:)).deduplicated()
    }

    private func displayCategories(_ categories: [PluginCategory]) -> [PluginCategory] {
        let uniqueCategories = categories.deduplicated()
        let specificCategories = uniqueCategories.filter { $0 != .utility }
        return specificCategories.nonEmpty ?? [.utility]
    }

    private func inferredCategories(for plugin: LoadedPlugin) -> [PluginCategory] {
        var categories: [PluginCategory] = []
        if plugin.instance is any TranscriptionEnginePlugin { categories.append(.transcription) }
        if plugin.instance is any TTSProviderPlugin { categories.append(.tts) }
        if plugin.instance is any LLMProviderPlugin { categories.append(.llm) }
        if plugin.instance is any PostProcessorPlugin { categories.append(.postProcessor) }
        if plugin.instance is any ActionPlugin { categories.append(.action) }
        if plugin.instance is any MemoryStoragePlugin { categories.append(.memory) }
        return categories
    }

    private func resolvedHosting(for plugin: LoadedPlugin, registryPlugin: RegistryPlugin?) -> PluginHosting {
        if let hosting = registryPlugin?.hosting {
            return hosting
        }
        if let hosting = plugin.manifest.hosting {
            return hosting
        }
        let requiresAPIKey = registryPlugin?.requiresAPIKey == true || plugin.manifest.requiresAPIKey == true
        return PluginHosting.fallback(requiresAPIKey: requiresAPIKey)
    }

    private func integrationSource(for plugin: LoadedPlugin, registryPlugin: RegistryPlugin?) -> IntegrationPluginSource {
        if plugin.isBundled {
            return .builtIn
        }
        if registryPlugin?.source == .community {
            return .community
        }
        if registryPlugin != nil {
            return .official
        }
        return .manual
    }

    private func integrationSource(for plugin: RegistryPlugin) -> IntegrationPluginSource {
        plugin.source == .community ? .community : .official
    }

    private var localPluginCount: Int {
        pluginManager.loadedPlugins.count { plugin in
            let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id })
            return resolvedHosting(for: plugin, registryPlugin: registryPlugin) == .local
        }
    }

    private var cloudPluginCount: Int {
        pluginManager.loadedPlugins.count { plugin in
            let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id })
            return resolvedHosting(for: plugin, registryPlugin: registryPlugin) == .cloud
        }
    }

    private var filteredInstalledPlugins: [LoadedPlugin] {
        pluginManager.loadedPlugins
            .sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }
    }

    private var installedTab: some View {
        LazyVStack(spacing: 0) {
            if filteredInstalledPlugins.isEmpty {
                IntegrationEmptyState(
                    title: String(localized: "No installed plugins yet."),
                    systemImage: "puzzlepiece.extension"
                )
            } else {
                ForEach(Array(filteredInstalledPlugins.enumerated()), id: \.element.id) { index, plugin in
                    let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id })
                    InstalledPluginRow(
                        plugin: plugin,
                        categories: categoriesForPlugin(plugin, registryPlugin: registryPlugin),
                        source: integrationSource(for: plugin, registryPlugin: registryPlugin),
                        installInfo: registryService.installInfo(for: plugin.id),
                        installState: registryService.installStates[plugin.id],
                        externalNotice: pluginManager.externalBundleNotice(
                            for: plugin.id,
                            registryPlugin: registryPlugin
                        ),
                        hosting: resolvedHosting(for: plugin, registryPlugin: registryPlugin),
                        registryPlugin: registryPlugin,
                        onUpdate: {
                            if let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id }) {
                                startInstall(registryPlugin)
                            }
                        },
                        onUninstall: {
                            pluginToUninstall = plugin
                            showUninstallAlert = true
                        }
                    )

                    if index < filteredInstalledPlugins.count - 1 {
                        Divider()
                            .padding(.leading, 62)
                    }
                }
            }

            if !filteredInstalledPlugins.isEmpty {
                Divider()
                    .padding(.leading, 62)
            }

            if !pluginManager.incompatibleExternalBundles.isEmpty {
                ForEach(pluginManager.incompatibleExternalBundles.values.sorted { $0.pluginName < $1.pluginName }, id: \.pluginId) { bundle in
                    IncompatibleBundleRow(bundle: bundle)
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .background {
            integrationGroupedSurface(cornerRadius: 16)
        }
        .task {
            await registryService.fetchRegistry()
        }
    }

    // MARK: - Available Tab

    private var availablePlugins: [RegistryPlugin] {
        let available = registryService.registry.filter { registryPlugin in
            let info = registryService.installInfo(for: registryPlugin.id)
            if case .notInstalled = info { return true }
            return false
        }
        return available.sorted {
            let d0 = $0.downloadCount ?? 0
            let d1 = $1.downloadCount ?? 0
            if d0 != d1 { return d0 > d1 }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    private var sourceFilteredAvailablePlugins: [RegistryPlugin] {
        availablePlugins.filter { plugin in
            includeCommunityPlugins || plugin.source != .community
        }
    }

    private var discoverCapabilityOptions: [PluginCategory] {
        let presentCategories = Set(sourceFilteredAvailablePlugins.flatMap { plugin in
            displayCategories(categories(from: plugin.categories))
        })
        return PluginCategory.allCases.filter { presentCategories.contains($0) }
    }

    private var filteredAvailablePlugins: [RegistryPlugin] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceFilteredAvailablePlugins
            .filter { plugin in
                guard !selectedCapabilityFilters.isEmpty else { return true }
                let pluginCategories = Set(displayCategories(categories(from: plugin.categories)))
                return !pluginCategories.isDisjoint(with: selectedCapabilityFilters)
            }
            .filter { plugin in
                guard !trimmedQuery.isEmpty else { return true }
                return plugin.name.localizedCaseInsensitiveContains(trimmedQuery)
                    || plugin.localizedDescription.localizedCaseInsensitiveContains(trimmedQuery)
                    || plugin.author.localizedCaseInsensitiveContains(trimmedQuery)
                    || plugin.category.localizedCaseInsensitiveContains(trimmedQuery)
                    || categories(from: plugin.categories).contains { category in
                        category.badgeTitle.localizedCaseInsensitiveContains(trimmedQuery)
                            || category.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                            || category.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
                    }
            }
    }

    private var availableTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            discoverFilterBar

            switch registryService.fetchState {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .error(let message):
                VStack(spacing: 8) {
                    Text(String(localized: "Failed to load plugins."))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(String(localized: "Retry")) {
                        Task { await registryService.fetchRegistry(force: true) }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            case .loaded:
                if filteredAvailablePlugins.isEmpty {
                    IntegrationEmptyState(
                        title: String(localized: "No available plugins match this search or filter."),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    .background {
                        integrationGroupedSurface(cornerRadius: 16)
                    }
                } else {
                    discoverSections
                }
            }
        }
        .task {
            await registryService.fetchRegistry()
        }
        .onChange(of: includeCommunityPlugins) { _, _ in
            normalizeCapabilityFilters()
        }
    }

    private var discoverFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                discoverSearchField

                discoverCapabilityMenu
                discoverCommunityToggle
            }

            VStack(alignment: .leading, spacing: 8) {
                discoverSearchField

                HStack(spacing: 12) {
                    discoverCapabilityMenu
                    discoverCommunityToggle
                }
            }
        }
    }

    private var discoverCapabilityMenu: some View {
        Menu {
            Button {
                selectedCapabilityFilters.removeAll()
            } label: {
                Label(String(localized: "All functions"), systemImage: selectedCapabilityFilters.isEmpty ? "checkmark" : "line.3.horizontal.decrease.circle")
            }

            if !discoverCapabilityOptions.isEmpty {
                Divider()

                ForEach(discoverCapabilityOptions, id: \.self) { category in
                    Button {
                        toggleCapabilityFilter(category)
                    } label: {
                        Label(
                            category.badgeTitle,
                            systemImage: selectedCapabilityFilters.contains(category) ? "checkmark" : category.iconSystemName
                        )
                    }
                }
            }
        } label: {
            Label(capabilityFilterTitle, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private var discoverCommunityToggle: some View {
        Toggle(isOn: $includeCommunityPlugins) {
            Label(String(localized: "Community"), systemImage: "person.2")
                .font(.caption.weight(.medium))
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .fixedSize()
    }

    private var capabilityFilterTitle: String {
        if selectedCapabilityFilters.isEmpty {
            return String(localized: "All functions")
        }

        let selected = PluginCategory.allCases.filter { selectedCapabilityFilters.contains($0) }
        if selected.count == 1, let category = selected.first {
            return category.badgeTitle
        }

        return String(localized: "\(selected.count) functions")
    }

    private func toggleCapabilityFilter(_ category: PluginCategory) {
        if selectedCapabilityFilters.contains(category) {
            selectedCapabilityFilters.remove(category)
        } else {
            selectedCapabilityFilters.insert(category)
        }
    }

    private func normalizeCapabilityFilters() {
        let availableCategories = Set(discoverCapabilityOptions)
        selectedCapabilityFilters = selectedCapabilityFilters.intersection(availableCategories)
    }

    private var discoverSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search plugins"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var discoverSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(discoverPluginSections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(section.tint)
                        Text(section.title)
                            .font(.headline)
                        Text("\(section.plugins.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 4)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(section.plugins.enumerated()), id: \.element.id) { index, plugin in
                            AvailablePluginRow(
                                plugin: plugin,
                                categories: displayCategories(categories(from: plugin.categories)),
                                source: integrationSource(for: plugin),
                                installState: registryService.installStates[plugin.id],
                                onInstall: {
                                    startInstall(plugin)
                                }
                            )

                            if index < section.plugins.count - 1 {
                                Divider()
                                    .padding(.leading, 62)
                            }
                        }
                    }
                    .background {
                        integrationGroupedSurface(cornerRadius: 16)
                    }
                }
            }
        }
    }

    private var discoverPluginSections: [DiscoverPluginSection] {
        let community = filteredAvailablePlugins.filter { $0.source == .community }
        let official = filteredAvailablePlugins.filter { $0.source == .official }

        return [
            DiscoverPluginSection(
                title: String(localized: "Marketplace"),
                systemImage: "sparkles",
                tint: .indigo,
                plugins: official
            ),
            DiscoverPluginSection(
                title: String(localized: "Community Plugins"),
                systemImage: "person.2",
                tint: .purple,
                plugins: community
            )
        ].filter { !$0.plugins.isEmpty }
    }

    private var manualTab: some View {
        LazyVStack(spacing: 0) {
            ManualInstallRow(
                onInstallFromFile: installFromFile,
                onOpenPluginsFolder: pluginManager.openPluginsFolder
            )

            if pluginManager.incompatibleExternalBundles.isEmpty {
                Divider()
                    .padding(.leading, 62)
                IntegrationEmptyState(
                    title: String(localized: "No external compatibility issues."),
                    systemImage: "checkmark.circle"
                )
            } else {
                Divider()
                    .padding(.leading, 62)
                ForEach(pluginManager.incompatibleExternalBundles.values.sorted { $0.pluginName < $1.pluginName }, id: \.pluginId) { bundle in
                    IncompatibleBundleRow(bundle: bundle)
                    Divider()
                        .padding(.leading, 62)
                }
            }
        }
        .background {
            integrationGroupedSurface(cornerRadius: 16)
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

    private func startInstall(_ plugin: RegistryPlugin) {
        if let notice = pluginManager.externalBundleNotice(for: plugin.id, registryPlugin: plugin),
           notice.requiresConfirmation {
            pendingBoundaryUpgradePlugin = plugin
            pendingBoundaryUpgradeNotice = notice
            return
        }

        Task {
            await registryService.downloadAndInstall(plugin)
            PluginManager.shared.setPluginEnabled(plugin.id, enabled: true)
        }
    }

    private func boundaryUpgradeMessage(for plugin: RegistryPlugin, notice: ExternalBundleNotice?) -> String {
        switch notice {
        case .boundaryUpgradeRequired(let installedVersion, let availableVersion):
            return String(
                localized: "Installing \(plugin.name) \(availableVersion) will replace an older external plugin bundle (\(installedVersion)) that was kept for another TypeWhisper runtime. Older app versions may stop using that bundle after this replacement."
            )
        default:
            return String(
                localized: "Installing this plugin will replace an older external bundle that was kept for another TypeWhisper runtime. Older app versions may stop using that bundle after this replacement."
            )
        }
    }
}

// MARK: - Shared Components

private struct DiscoverPluginSection: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let plugins: [RegistryPlugin]

    var id: String { title }
}

private struct HostingSummaryInline: View {
    let localCount: Int
    let cloudCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Label("\(localCount) \(String(localized: "Local"))", systemImage: "desktopcomputer")
                .foregroundStyle(.green)
            Label("\(cloudCount) Cloud", systemImage: "cloud")
                .foregroundStyle(.cyan)
        }
        .font(.caption.weight(.medium))
    }
}

private func integrationGroupedSurface(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
}

private extension Array where Element: Hashable {
    func deduplicated() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }

    var nonEmpty: [Element]? {
        isEmpty ? nil : self
    }
}

private struct IntegrationEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct SourceBadge: View {
    let source: IntegrationPluginSource

    var body: some View {
        Label(source.title, systemImage: source.systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(source.tint.opacity(0.14)))
            .foregroundStyle(source.tint)
    }
}

private struct HostingBadge: View {
    let hosting: PluginHosting

    var body: some View {
        if hosting == .cloud {
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

private extension PluginCategory {
    var badgeTitle: String {
        switch self {
        case .transcription: String(localized: "Transcription")
        case .tts: String(localized: "TTS")
        case .llm: String(localized: "LLM")
        case .postProcessor: String(localized: "Post-processing")
        case .action: String(localized: "Actions")
        case .memory: String(localized: "Memory")
        case .utility: String(localized: "Utility")
        }
    }
}

private struct PluginCategoryBadge: View {
    let category: PluginCategory

    var body: some View {
        Label(category.badgeTitle, systemImage: category.iconSystemName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

private struct PluginBadgeLine: View {
    let source: IntegrationPluginSource
    let hosting: PluginHosting
    let categories: [PluginCategory]

    var body: some View {
        HStack(spacing: 6) {
            SourceBadge(source: source)
            HostingBadge(hosting: hosting)
            ForEach(categories, id: \.self) { category in
                PluginCategoryBadge(category: category)
            }
        }
    }
}

private struct IntegrationIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
    }
}

private struct InstalledPluginRow: View {
    let plugin: LoadedPlugin
    let categories: [PluginCategory]
    let source: IntegrationPluginSource
    let installInfo: PluginInstallInfo
    let installState: PluginRegistryService.InstallState?
    let externalNotice: ExternalBundleNotice?
    let hosting: PluginHosting
    let registryPlugin: RegistryPlugin?
    let onUpdate: () -> Void
    let onUninstall: () -> Void
    @State private var pluginActivity: PluginSettingsActivity?

    private let activityTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationIcon(
                systemName: registryPlugin?.iconSystemName ?? plugin.manifest.iconSystemName ?? "puzzlepiece.extension",
                tint: source.tint
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(plugin.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PluginBadgeLine(source: source, hosting: hosting, categories: categories)

                if let description = registryPlugin?.localizedDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let author = plugin.manifest.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let externalNotice {
                    Text(externalNotice.detailText)
                        .font(.caption2)
                        .foregroundStyle(externalNotice.badgeColor)
                        .lineLimit(1)
                }

                if let state = installState {
                    PluginInstallStateView(state: state, name: plugin.manifest.name)
                } else if case .updateAvailable = installInfo {
                    Button {
                        onUpdate()
                    } label: {
                        Label(String(localized: "Update"), systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                } else if let pluginActivity {
                    PluginSettingsActivityView(activity: pluginActivity)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { enabled in
                        PluginManager.shared.setPluginEnabled(plugin.id, enabled: enabled)
                    }
                ))
                .labelsHidden()
                .accessibilityLabel(String(localized: "Enable \(plugin.manifest.name)"))

                if plugin.supportsSettingsWindow {
                    Button {
                        PluginSettingsWindowManager.shared.present(plugin)
                    } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Settings for \(plugin.manifest.name)"))
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            refreshPluginActivity()
        }
        .onReceive(activityTimer) { _ in
            refreshPluginActivity()
        }
    }

    private func refreshPluginActivity() {
        guard plugin.isRuntimeLoaded else {
            pluginActivity = nil
            return
        }
        pluginActivity = (plugin.instance as? any PluginSettingsActivityReporting)?.currentSettingsActivity
    }
}

private struct AvailablePluginRow: View {
    let plugin: RegistryPlugin
    let categories: [PluginCategory]
    let source: IntegrationPluginSource
    let installState: PluginRegistryService.InstallState?
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationIcon(systemName: plugin.iconSystemName ?? "puzzlepiece.extension", tint: source.tint)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(plugin.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PluginBadgeLine(source: source, hosting: plugin.resolvedHosting, categories: categories)

                Text(plugin.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
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

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                if let state = installState {
                    PluginInstallStateView(state: state, name: plugin.name)
                }

                if case .error = installState {
                    Button(String(localized: "Retry")) {
                        onInstall()
                    }
                    .controlSize(.small)
                } else if installState == nil {
                    Button {
                        onInstall()
                    } label: {
                        Label(String(localized: "Install"), systemImage: "arrow.down.circle")
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Install \(plugin.name)"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ManualInstallRow: View {
    let onInstallFromFile: () -> Void
    let onOpenPluginsFolder: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationIcon(systemName: "folder.badge.plus", tint: .orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Manual Plugin Install"))
                    .font(.headline)
                Text(String(localized: "Install a local .bundle or .zip plugin package, or manage the plugins folder directly."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    onInstallFromFile()
                } label: {
                    Label(String(localized: "Install from File..."), systemImage: "plus")
                }
                Button {
                    onOpenPluginsFolder()
                } label: {
                    Label(String(localized: "Open Plugins Folder"), systemImage: "folder")
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct IncompatibleBundleRow: View {
    let bundle: IncompatibleExternalBundle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationIcon(systemName: "exclamationmark.triangle", tint: .orange)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(bundle.pluginName)
                        .font(.headline)
                    Text("v\(bundle.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(reasonText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(bundle.bundleURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var reasonText: String {
        switch bundle.reason {
        case .sdkCompatibility(let expected, let actual):
            if let actual {
                return String(localized: "Requires SDK \(expected), but this bundle declares \(actual).")
            }
            return String(localized: "Missing SDK compatibility metadata for this TypeWhisper runtime.")
        }
    }
}

private struct PluginInstallStateView: View {
    let state: PluginRegistryService.InstallState
    let name: String

    var body: some View {
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
            .accessibilityLabel(String(localized: "Downloading \(name)"))
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
    }
}

private extension ExternalBundleNotice {
    var detailText: String {
        switch self {
        case .legacyBundlePresent(let version):
            return String(localized: "External plugin bundle \(version) was kept for an older TypeWhisper line.")
        case .incompatibleWithCurrentRuntime(let version):
            return String(localized: "External plugin bundle \(version) is incompatible with this runtime.")
        case .bundledFallbackActive(let version):
            return String(localized: "External plugin bundle \(version) was skipped; the built-in plugin is active instead.")
        case .boundaryUpgradeRequired(let installedVersion, let availableVersion):
            return String(localized: "Marketplace replacement \(availableVersion) is available, but replacing external bundle \(installedVersion) requires confirmation.")
        }
    }

    var badgeColor: Color {
        switch self {
        case .legacyBundlePresent:
            return .secondary
        case .incompatibleWithCurrentRuntime, .bundledFallbackActive, .boundaryUpgradeRequired:
            return .orange
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
