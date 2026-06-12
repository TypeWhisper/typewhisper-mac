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
            rootView: PluginSettingsWindowContent(settingsView: settingsView)
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

private struct PluginSettingsWindowContent: View {
    let settingsView: AnyView

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            settingsView
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    var title: String {
        switch self {
        case .installed:
            return localizedAppText("My Plugins", de: "Meine Plugins")
        case .discover:
            return localizedAppText("Discover", de: "Entdecken")
        }
    }

    var systemImage: String {
        switch self {
        case .installed:
            return "checkmark.circle"
        case .discover:
            return "sparkles"
        }
    }
}

private enum DiscoverSort: String, CaseIterable {
    case popularity
    case name

    var title: String {
        switch self {
        case .popularity:
            return localizedAppText("Popularity", de: "Beliebtheit")
        case .name:
            return String(localized: "Name")
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
    @AppStorage(UserDefaultsKeys.selectedIntegrationTab) private var selectedTab: IntegrationTab = .discover
    @State private var showUninstallAlert = false
    @State private var pluginToUninstall: LoadedPlugin?
    @State private var pendingBoundaryUpgradePlugin: RegistryPlugin?
    @State private var pendingBoundaryUpgradeNotice: ExternalBundleNotice?
    @State private var installFromFileError: String?
    @State private var includeCommunityPlugins = true
    @State private var selectedCapabilityFilters: Set<PluginCategory> = []
    @State private var searchText = ""
    @State private var discoverSort: DiscoverSort = .popularity

    var body: some View {
        VStack(spacing: 0) {
            integrationsHeader

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    integrationTabHeader

                    switch selectedTab {
                    case .installed:
                        installedTab
                    case .discover:
                        availableTab
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
                    let installed = await registryService.downloadAndInstall(plugin)
                    if installed {
                        completeSuccessfulInstall(pluginId: plugin.id, registryPlugin: plugin)
                    }
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
                Label(String(localized: "Open Plugins Folder"), systemImage: "folder")
            }
            .controlSize(.small)
            .help(String(localized: "Open Plugins Folder"))

            Button {
                installFromFile()
            } label: {
                Label(localizedAppText("Install Plugin", de: "Plugin installieren"), systemImage: "plus")
            }
            .controlSize(.small)
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
            return localizedAppText(
                "\(installed) installed · \(updates) updates · \(available) available",
                de: "\(installed) installiert · \(updates) Updates · \(available) verfügbar",
                ja: "\(installed)件インストール済み · \(updates)件の更新 · \(available)件利用可能"
            )
        }
        return localizedAppText(
            "\(installed) installed · \(available) available",
            de: "\(installed) installiert · \(available) verfügbar",
            ja: "\(installed)件インストール済み · \(available)件利用可能"
        )
    }

    private func normalizeDiscoverState() {
        if selectedTab != .discover {
            searchText = ""
            selectedCapabilityFilters.removeAll()
        }
    }

    private var integrationTabHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                integrationTabBar
                    .frame(width: 580)

                HostingSummaryInline(localCount: localPluginCount, cloudCount: cloudPluginCount)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                integrationTabBar
                    .frame(maxWidth: .infinity)

                HostingSummaryInline(localCount: localPluginCount, cloudCount: cloudPluginCount)
            }
        }
        .padding(.bottom, 4)
    }

    private var integrationTabBar: some View {
        HStack(spacing: 12) {
            ForEach(IntegrationTab.allCases, id: \.self) { tab in
                integrationTabCard(tab)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func integrationTabCard(_ tab: IntegrationTab) -> some View {
        let isSelected = selectedTab == tab
        let isDiscover = tab == .discover
        let inactiveTint = isDiscover ? Color.blue.opacity(1.0) : Color.primary.opacity(0.84)
        let inactiveTitle = isDiscover ? Color.primary.opacity(1.0) : Color.primary.opacity(0.92)
        let inactiveSubtitle = isDiscover ? Color.primary.opacity(0.72) : Color.primary.opacity(0.62)
        let inactiveBorder = isDiscover ? Color.blue.opacity(0.50) : Color.white.opacity(0.18)
        let inactiveBadgeFill = isDiscover ? Color.blue.opacity(0.22) : Color.white.opacity(0.10)
        let inactiveBadgeForeground = isDiscover ? Color.blue.opacity(1.0) : Color.primary.opacity(0.82)

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedTab = tab
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : inactiveTint)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : inactiveTitle)
                        .lineLimit(1)

                    Text(integrationTabSubtitle(for: tab))
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.82) : inactiveSubtitle)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(integrationTabCount(for: tab))")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.accentColor : inactiveBadgeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.95) : inactiveBadgeFill)
                    }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 56, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.88) : Color.black.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.32) : inactiveBorder, lineWidth: isSelected ? 1.25 : 1.1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(integrationTabSubtitle(for: tab))
    }

    private func integrationTabCount(for tab: IntegrationTab) -> Int {
        switch tab {
        case .installed:
            return pluginManager.loadedPlugins.count
        case .discover:
            return availablePlugins.count
        }
    }

    private func integrationTabSubtitle(for tab: IntegrationTab) -> String {
        let count = integrationTabCount(for: tab)
        switch tab {
        case .installed:
            return localizedAppText("\(count) installed", de: "\(count) installiert", ja: "\(count)件インストール済み")
        case .discover:
            return localizedAppText("\(count) available", de: "\(count) verfügbar", ja: "\(count)件利用可能")
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
        if plugin.instance is any FileJobAutomationPlugin { categories.append(.fileAutomation) }
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

    private func resolvedPluginDetailURLString(for plugin: RegistryPlugin) -> String? {
        pluginDetailURLString(pluginId: plugin.id, registryDetailsURL: plugin.detailsURL)
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
        LazyVStack(spacing: 12) {
            if filteredInstalledPlugins.isEmpty {
                IntegrationEmptyState(
                    title: String(localized: "No installed plugins yet."),
                    systemImage: "puzzlepiece.extension"
                )
                .background {
                    integrationGroupedSurface(cornerRadius: 16)
                }
            } else {
                ForEach(filteredInstalledPlugins, id: \.id) { plugin in
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
                        onRepair: {
                            if let registryPlugin = registryService.registry.first(where: { $0.id == plugin.id }) {
                                startInstall(registryPlugin)
                            }
                        },
                        onUninstall: {
                            pluginToUninstall = plugin
                            showUninstallAlert = true
                        }
                    )
                    .background {
                        integrationGroupedSurface(cornerRadius: 14)
                    }
                }
            }

            if !pluginManager.incompatibleExternalBundles.isEmpty {
                ForEach(pluginManager.incompatibleExternalBundles.values.sorted { $0.pluginName < $1.pluginName }, id: \.pluginId) { bundle in
                    IncompatibleBundleRow(bundle: bundle)
                        .background {
                            integrationGroupedSurface(cornerRadius: 14)
                        }
                }
            }

            if !availablePlugins.isEmpty {
                installedDiscoverBanner
            }
        }
        .task {
            await registryService.fetchRegistry()
        }
    }

    // MARK: - Available Tab

    private var availablePlugins: [RegistryPlugin] {
        registryService.registry.filter { registryPlugin in
            let info = registryService.installInfo(for: registryPlugin.id)
            if case .notInstalled = info { return true }
            return false
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
            .sorted { lhs, rhs in
                switch discoverSort {
                case .popularity:
                    let lhsDownloads = lhs.downloadCount ?? 0
                    let rhsDownloads = rhs.downloadCount ?? 0
                    if lhsDownloads != rhsDownloads { return lhsDownloads > rhsDownloads }
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                case .name:
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                }
            }
    }

    private var availableTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            discoverHero
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
                    discoverPluginList
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
                discoverSortMenu
                discoverCommunityToggle
            }

            VStack(alignment: .leading, spacing: 8) {
                discoverSearchField

                HStack(spacing: 12) {
                    discoverCapabilityMenu
                    discoverSortMenu
                    discoverCommunityToggle
                }
            }
        }
    }

    private var discoverHero: some View {
        Button {
            openExternalURL(localizedTypeWhisperAddonsURLString())
        } label: {
            discoverHeroContent
        }
        .buttonStyle(.plain)
        .help(localizedAppText("Open TypeWhisper add-ons website", de: "TypeWhisper-Add-ons-Webseite öffnen"))
        .accessibilityLabel(localizedAppText("Open TypeWhisper add-ons website", de: "TypeWhisper-Add-ons-Webseite öffnen"))
    }

    private var discoverHeroContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                discoverHeroImage(width: 44, height: 32)

                discoverHeroCompactCopy

                Spacer(minLength: 12)

                discoverHeroCompactLink
            }

            VStack(alignment: .leading, spacing: 8) {
                discoverHeroCompactCopy
                discoverHeroCompactLink
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .controlBackgroundColor),
                            Color.blue.opacity(0.06),
                            Color.purple.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.blue.opacity(0.16), lineWidth: 1)
                )
        }
    }

    private var discoverHeroCompactCopy: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(localizedAppText("Browse plugin catalog", de: "Plugin-Katalog durchsuchen"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(localizedAppText(
                "Browse add-ons on the TypeWhisper website and install them directly here.",
                de: "Durchsuche Add-ons auf der TypeWhisper-Webseite und installiere sie direkt hier."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    private var discoverHeroCompactLink: some View {
        Label(localizedAppText("Open online catalog", de: "Online-Katalog öffnen"), systemImage: "arrow.up.right.square")
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var installedDiscoverBanner: some View {
        Button {
            selectedTab = .discover
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    installedDiscoverBannerCopy

                    Spacer(minLength: 12)

                    discoverHeroImage(width: 120, height: 82)
                }

                installedDiscoverBannerCopy
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor),
                                Color.blue.opacity(0.10),
                                Color.purple.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .help(localizedAppText("Discover plugins", de: "Plugins entdecken"))
        .accessibilityLabel(localizedAppText("Discover plugins", de: "Plugins entdecken"))
    }

    private var installedDiscoverBannerCopy: some View {
        discoverHeroCopy(
            title: localizedAppText("Discover new plugins", de: "Neue Plugins entdecken"),
            subtitle: localizedAppText(
                "Browse available add-ons and install the next integration directly here.",
                de: "Durchsuche verfügbare Add-ons und installiere die nächste Integration direkt hier."
            ),
            actionTitle: localizedAppText("Discover plugins", de: "Plugins entdecken"),
            actionSystemImage: "arrow.right",
            titleFont: .headline.weight(.semibold),
            subtitleFont: .caption,
            actionFont: .caption.weight(.semibold)
        )
    }

    private func discoverHeroCopy(
        title: String,
        subtitle: String,
        actionTitle: String,
        actionSystemImage: String,
        titleFont: Font = .title2.weight(.semibold),
        subtitleFont: Font = .callout,
        actionFont: Font = .callout.weight(.semibold)
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(subtitleFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(actionTitle, systemImage: actionSystemImage)
                .labelStyle(.titleAndIcon)
                .font(actionFont)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                }
                .foregroundStyle(.white)
        }
    }

    private func discoverHeroImage(width: CGFloat, height: CGFloat) -> some View {
        Image("IntegrationsHeroPuzzle")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }

    private var discoverCapabilityMenu: some View {
        Menu {
            Button {
                selectedCapabilityFilters.removeAll()
            } label: {
                Label(localizedAppText("All functions", de: "Alle Funktionen"), systemImage: selectedCapabilityFilters.isEmpty ? "checkmark" : "line.3.horizontal.decrease.circle")
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

    private var discoverSortMenu: some View {
        Menu {
            ForEach(DiscoverSort.allCases, id: \.self) { sort in
                Button {
                    discoverSort = sort
                } label: {
                    Label(sort.title, systemImage: discoverSort == sort ? "checkmark" : "arrow.up.arrow.down")
                }
            }
        } label: {
            Label(discoverSort.title, systemImage: "arrow.up.arrow.down")
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
            return localizedAppText("All functions", de: "Alle Funktionen")
        }

        let selected = PluginCategory.allCases.filter { selectedCapabilityFilters.contains($0) }
        if selected.count == 1, let category = selected.first {
            return category.badgeTitle
        }

        return localizedAppText("\(selected.count) functions", de: "\(selected.count) Funktionen", ja: "\(selected.count)件の機能")
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
            TextField(
                localizedAppText(
                    "Search plugins, providers, or features",
                    de: "Plugins, Anbieter oder Funktionen suchen"
                ),
                text: $searchText
            )
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
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var discoverPluginList: some View {
        LazyVStack(spacing: 12) {
            ForEach(filteredAvailablePlugins, id: \.id) { plugin in
                let detailsURLString = resolvedPluginDetailURLString(for: plugin)
                AvailablePluginRow(
                    plugin: plugin,
                    categories: displayCategories(categories(from: plugin.categories)),
                    source: integrationSource(for: plugin),
                    installState: registryService.installStates[plugin.id],
                    detailsURLString: detailsURLString,
                    onInstall: {
                        startInstall(plugin)
                    },
                    onOpenDetails: {
                        openExternalURL(detailsURLString)
                    }
                )
                .background {
                    integrationGroupedSurface(cornerRadius: 14)
                }
            }
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
                let manifest = try await registryService.installFromFile(url)
                completeSuccessfulInstall(pluginId: manifest.id, registryPlugin: nil)
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
            let installed = await registryService.downloadAndInstall(plugin)
            if installed {
                completeSuccessfulInstall(pluginId: plugin.id, registryPlugin: plugin)
            }
        }
    }

    @MainActor
    private func completeSuccessfulInstall(pluginId: String, registryPlugin: RegistryPlugin?) {
        selectedTab = .installed

        let resolvedRegistryPlugin = registryPlugin ?? registryService.registry.first { $0.id == pluginId }
        enableInstalledPluginIfNeeded(pluginId)

        guard let installedPlugin = pluginManager.loadedPlugins.first(where: { $0.id == pluginId }),
              shouldOpenSettingsAfterInstall(installedPlugin, registryPlugin: resolvedRegistryPlugin) else {
            return
        }

        PluginSettingsWindowManager.shared.present(installedPlugin)
    }

    @MainActor
    private func enableInstalledPluginIfNeeded(_ pluginId: String) {
        guard let installedPlugin = pluginManager.loadedPlugins.first(where: { $0.id == pluginId }),
              !installedPlugin.isEnabled || !installedPlugin.isRuntimeLoaded else {
            return
        }

        PluginManager.shared.setPluginEnabled(pluginId, enabled: true)
    }

    @MainActor
    private func shouldOpenSettingsAfterInstall(_ plugin: LoadedPlugin, registryPlugin: RegistryPlugin?) -> Bool {
        guard plugin.supportsSettingsWindow else { return false }

        if registryPlugin?.requiresAPIKey == true || plugin.manifest.requiresAPIKey == true {
            return true
        }

        if let engine = plugin.instance as? any TranscriptionEnginePlugin,
           !engine.isConfigured {
            return true
        }

        if let provider = plugin.instance as? any LLMProviderPlugin,
           !provider.isAvailable {
            return true
        }

        if let provider = plugin.instance as? any TTSProviderPlugin,
           !provider.isConfigured {
            return true
        }

        return false
    }

    private func openExternalURL(_ urlString: String?) {
        guard let url = validatedExternalURL(urlString) else { return }
        NSWorkspace.shared.open(url)
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

private let typeWhisperAddonSlugsByPluginID: [String: String] = [
    "com.typewhisper.assemblyai": "assemblyai",
    "com.typewhisper.cartesia": "cartesia",
    "com.typewhisper.cerebras": "cerebras",
    "com.typewhisper.claude": "claude",
    "com.typewhisper.cloudflare-asr": "cloudflare-asr",
    "com.typewhisper.cohere": "cohere",
    "com.typewhisper.deepgram": "deepgram",
    "com.typewhisper.elevenlabs": "elevenlabs",
    "com.typewhisper.memory.file": "file-memory",
    "com.typewhisper.filler-words": "filler-words",
    "com.typewhisper.fireworks": "fireworks",
    "com.typewhisper.gemini": "gemini",
    "com.typewhisper.gemma4": "gemma4",
    "com.typewhisper.gladia": "gladia",
    "com.typewhisper.google-cloud-stt": "google-cloud-stt",
    "com.typewhisper.granite": "granite",
    "com.typewhisper.groq": "groq",
    "com.typewhisper.linear": "linear",
    "com.typewhisper.livetranscript": "live-transcript",
    "com.typewhisper.obsidian": "obsidian",
    "com.typewhisper.openai-compatible": "openai-compatible",
    "com.typewhisper.openai": "openai",
    "com.typewhisper.memory.openai-vector": "openai-vector-memory",
    "com.typewhisper.openrouter": "openrouter",
    "com.typewhisper.parakeet": "parakeet",
    "com.typewhisper.qwen3": "qwen3-asr",
    "com.typewhisper.reson8": "reson8",
    "com.typewhisper.script": "script-runner",
    "com.typewhisper.smallest-pulse": "smallest-pulse",
    "com.typewhisper.soniox": "soniox",
    "com.typewhisper.speechanalyzer": "apple-speech",
    "com.typewhisper.speechmatics": "speechmatics",
    "com.typewhisper.tts.supertonic": "supertonic",
    "com.typewhisper.voxtral": "voxtral",
    "com.typewhisper.webhook": "webhook",
    "com.typewhisper.whisperkit": "whisperkit",
    "com.typewhisper.xai": "xai-grok"
]

private let supportedTypeWhisperWebsiteLocalePathComponents: Set<String> = ["de", "en"]

private func localizedTypeWhisperAddonsURLString() -> String {
    "https://www.typewhisper.com/\(typeWhisperWebsiteLocalePathComponent())/addons/"
}

private func localizedTypeWhisperAddonURLString(slug: String) -> String {
    "https://www.typewhisper.com/\(typeWhisperWebsiteLocalePathComponent())/addons/\(slug)/"
}

private func typeWhisperWebsiteLocalePathComponent() -> String {
    let languageCode = preferredAppLanguageCode()
        .split(separator: "-")
        .first
        .map(String.init) ?? "en"
    return supportedTypeWhisperWebsiteLocalePathComponents.contains(languageCode) ? languageCode : "en"
}

private func localizedTypeWhisperAddonURLString(from urlString: String?) -> String? {
    guard let url = validatedExternalURL(urlString),
          let host = url.host()?.lowercased(),
          host == "typewhisper.com" || host == "www.typewhisper.com" else {
        return nil
    }

    let components = url.pathComponents.filter { $0 != "/" }
    if components.count >= 2, components[0] == "addons" {
        return localizedTypeWhisperAddonURLString(slug: components[1])
    }
    if components.count >= 3,
       supportedTypeWhisperWebsiteLocalePathComponents.contains(components[0]),
       components[1] == "addons" {
        return localizedTypeWhisperAddonURLString(slug: components[2])
    }

    return nil
}

private func pluginDetailURLString(
    pluginId: String,
    registryDetailsURL: String?,
    manifestDetailsURL: String? = nil
) -> String? {
    if let slug = typeWhisperAddonSlugsByPluginID[pluginId] {
        return localizedTypeWhisperAddonURLString(slug: slug)
    }

    if let localizedRegistryDetailsURL = localizedTypeWhisperAddonURLString(from: registryDetailsURL) {
        return localizedRegistryDetailsURL
    }

    if validatedExternalURL(registryDetailsURL) != nil {
        return registryDetailsURL
    }

    if let localizedManifestDetailsURL = localizedTypeWhisperAddonURLString(from: manifestDetailsURL) {
        return localizedManifestDetailsURL
    }

    if validatedExternalURL(manifestDetailsURL) != nil {
        return manifestDetailsURL
    }

    return nil
}

private struct HostingSummaryInline: View {
    let localCount: Int
    let cloudCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(localizedAppText("\(localCount) Local", de: "\(localCount) lokal", ja: "\(localCount)件ローカル"), systemImage: "desktopcomputer")
                .foregroundStyle(.green)
            Label(localizedAppText("\(cloudCount) Cloud", de: "\(cloudCount) Cloud", ja: "\(cloudCount)件クラウド"), systemImage: "cloud")
                .foregroundStyle(.cyan)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.10))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
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

private func validatedExternalURL(_ urlString: String?) -> URL? {
    guard let value = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          (scheme == "https" || scheme == "http"),
          components.host != nil,
          let url = components.url else {
        return nil
    }
    return url
}

private func validatedHTTPSURL(_ urlString: String?) -> URL? {
    guard let url = validatedExternalURL(urlString),
          url.scheme?.lowercased() == "https" else {
        return nil
    }
    return url
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
        case .fileAutomation: String(localized: "File automation")
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
    var imageURL: URL?
    var darkImageURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedImage: NSImage?

    private var resolvedImageURL: URL? {
        if colorScheme == .dark {
            darkImageURL ?? imageURL
        } else {
            imageURL
        }
    }

    var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 44, height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        }
        .task(id: resolvedImageURL) {
            guard let resolvedImageURL else {
                loadedImage = nil
                return
            }

            loadedImage = nil
            var request = URLRequest(url: resolvedImageURL)
            request.timeoutInterval = 15
            let imageData = try? await URLSession.shared.data(for: request).0

            guard !Task.isCancelled else { return }
            loadedImage = imageData.flatMap(NSImage.init(data:))
        }
    }
}

private extension LoadedPlugin {
    var iconResourceURL: URL? {
        guard let resourceName = manifest.iconResourceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resourceName.isEmpty else {
            return nil
        }

        let resourcesURL = (bundle.resourceURL ?? sourceURL.appendingPathComponent("Contents/Resources"))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let url = resourcesURL
            .appendingPathComponent(resourceName)
            .resolvingSymlinksInPath()
            .standardizedFileURL

        guard url.pathComponents.starts(with: resourcesURL.pathComponents),
              url.pathComponents.count > resourcesURL.pathComponents.count else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return url
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
    let onRepair: () -> Void
    let onUninstall: () -> Void
    @State private var pluginActivity: PluginSettingsActivity?
    @State private var modelsExpanded = false
    @State private var modelPendingDeletion: PluginModelInfo?
    @State private var deletingModelId: String?
    @State private var modelDeleteError: String?

    private let activityTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let models = downloadedModels

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IntegrationIcon(
                    systemName: registryPlugin?.iconSystemName ?? plugin.manifest.iconSystemName ?? "puzzlepiece.extension",
                    tint: source.tint,
                    imageURL: iconURL,
                    darkImageURL: iconDarkURL
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

                    if !models.isEmpty {
                        Button {
                            modelsExpanded.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: modelsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 10)
                                Label(downloadedModelCountTitle(models.count), systemImage: "externaldrive")
                                    .labelStyle(.titleAndIcon)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(downloadedModelCountTitle(models.count))
                    }

                    if let externalNotice {
                        Text(externalNotice.detailText)
                            .font(.caption2)
                            .foregroundStyle(externalNotice.badgeColor)
                            .lineLimit(1)
                    }

                    pluginActions
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if plugin.supportsSettingsWindow {
                        Button {
                            PluginSettingsWindowManager.shared.present(plugin)
                        } label: {
                            Label(String(localized: "Settings"), systemImage: "gearshape")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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

                    if hasOverflowActions {
                        Menu {
                            if let detailsURL {
                                Button {
                                    NSWorkspace.shared.open(detailsURL)
                                } label: {
                                    Label(localizedAppText("Details", de: "Details"), systemImage: "arrow.up.right.square")
                                }
                            }

                            if let homepageURL {
                                Button {
                                    NSWorkspace.shared.open(homepageURL)
                                } label: {
                                    Label(localizedAppText("Homepage", de: "Homepage"), systemImage: "globe")
                                }
                            }

                            if detailsURL != nil || homepageURL != nil {
                                Divider()
                            }

                            if canRepairInstallation {
                                Button {
                                    onRepair()
                                } label: {
                                    Label(localizedAppText("Repair Installation", de: "Installation reparieren"), systemImage: "arrow.down.app")
                                }
                            }

                            if !plugin.isBundled {
                                if canRepairInstallation {
                                    Divider()
                                }

                                Button(role: .destructive) {
                                    onUninstall()
                                } label: {
                                    Label(String(localized: "Uninstall"), systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 26, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(localizedAppText("More Actions", de: "Weitere Aktionen"))
                        .accessibilityLabel(localizedAppText("More Actions for \(plugin.manifest.name)", de: "Weitere Aktionen für \(plugin.manifest.name)", ja: "\(plugin.manifest.name)のその他の操作"))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if modelsExpanded && !models.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        DownloadedPluginModelRow(
                            model: model,
                            isDeleting: deletingModelId == model.id,
                            onDelete: {
                                modelPendingDeletion = model
                            }
                        )
                        .disabled(deletingModelId != nil)

                        if index < models.count - 1 {
                            Divider()
                                .padding(.leading, 96)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            refreshPluginActivity()
        }
        .onReceive(activityTimer) { _ in
            refreshPluginActivity()
        }
        .alert(
            String(localized: "Remove Downloaded Model"),
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { model in
            Button(String(localized: "Remove"), role: .destructive) {
                deleteDownloadedModel(model)
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                modelPendingDeletion = nil
            }
        } message: { model in
            Text(deleteConfirmationMessage(for: model, downloadedCount: models.count))
        }
        .alert(
            String(localized: "Could Not Remove Model"),
            isPresented: Binding(
                get: { modelDeleteError != nil },
                set: { if !$0 { modelDeleteError = nil } }
            )
        ) {
            Button(String(localized: "OK")) { modelDeleteError = nil }
        } message: {
            if let modelDeleteError {
                Text(modelDeleteError)
            }
        }
    }

    private var downloadedModels: [PluginModelInfo] {
        guard plugin.isRuntimeLoaded,
              let modelManager = plugin.instance as? any PluginDownloadedModelManaging else {
            return []
        }
        return modelManager.downloadedModels
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    @ViewBuilder
    private var pluginActions: some View {
        if let state = installState {
            PluginInstallStateView(state: state, name: plugin.manifest.name)
        } else if case .updateAvailable = installInfo {
            Button {
                onUpdate()
            } label: {
                Label(String(localized: "Update"), systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        } else {
            if let pluginActivity {
                PluginSettingsActivityView(activity: pluginActivity)
            }
        }
    }

    private var canRepairInstallation: Bool {
        PluginRegistryService.canRepairInstalledPlugin(
            isBundled: plugin.isBundled,
            registryPlugin: registryPlugin,
            installInfo: installInfo,
            installState: installState,
            externalNotice: externalNotice
        )
    }

    private var detailsURL: URL? {
        validatedExternalURL(pluginDetailURLString(
            pluginId: plugin.id,
            registryDetailsURL: registryPlugin?.detailsURL,
            manifestDetailsURL: plugin.manifest.detailsURL
        ))
    }

    private var homepageURL: URL? {
        validatedExternalURL(registryPlugin?.homepageURL ?? plugin.manifest.homepageURL)
    }

    private var iconURL: URL? {
        validatedHTTPSURL(registryPlugin?.iconURL)
            ?? validatedHTTPSURL(plugin.manifest.iconURL)
            ?? plugin.iconResourceURL
    }

    private var iconDarkURL: URL? {
        validatedHTTPSURL(registryPlugin?.iconDarkURL)
            ?? validatedHTTPSURL(plugin.manifest.iconDarkURL)
    }

    private var hasOverflowActions: Bool {
        detailsURL != nil || homepageURL != nil || canRepairInstallation || !plugin.isBundled
    }

    private func downloadedModelCountTitle(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 downloaded model")
        }
        return String(localized: "\(count) downloaded models")
    }

    private func deleteConfirmationMessage(for model: PluginModelInfo, downloadedCount: Int) -> String {
        if downloadedCount <= 1 {
            return String(localized: "Remove \(model.displayName)? This will delete the downloaded model files and disable \(plugin.manifest.name).")
        }
        return String(localized: "Remove \(model.displayName)? This will delete the downloaded model files. \(plugin.manifest.name) will stay installed and enabled.")
    }

    private func deleteDownloadedModel(_ model: PluginModelInfo) {
        modelPendingDeletion = nil
        deletingModelId = model.id

        Task { @MainActor in
            do {
                try await PluginManager.shared.deleteDownloadedModel(pluginId: plugin.id, modelId: model.id)
            } catch {
                modelDeleteError = error.localizedDescription
            }
            deletingModelId = nil
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

private struct DownloadedPluginModelRow: View {
    let model: PluginModelInfo
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.loaded == true ? "checkmark.circle.fill" : "externaldrive")
                .foregroundStyle(model.loaded == true ? .green : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    if model.loaded == true {
                        Text(String(localized: "Loaded"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                if !model.sizeDescription.isEmpty || model.languageCount > 0 {
                    Text(modelDetailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if isDeleting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Remove downloaded model"))
                .accessibilityLabel(String(localized: "Remove \(model.displayName)"))
            }
        }
        .padding(.leading, 62)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
    }

    private var modelDetailText: String {
        var parts: [String] = []
        if !model.sizeDescription.isEmpty {
            parts.append(model.sizeDescription)
        }
        if model.languageCount > 0 {
            parts.append(String(localized: "\(model.languageCount) languages"))
        }
        return parts.joined(separator: " - ")
    }
}

private struct AvailablePluginRow: View {
    let plugin: RegistryPlugin
    let categories: [PluginCategory]
    let source: IntegrationPluginSource
    let installState: PluginRegistryService.InstallState?
    let detailsURLString: String?
    let onInstall: () -> Void
    let onOpenDetails: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationIcon(
                systemName: plugin.iconSystemName ?? "puzzlepiece.extension",
                tint: source.tint,
                imageURL: validatedHTTPSURL(plugin.iconURL),
                darkImageURL: validatedHTTPSURL(plugin.iconDarkURL)
            )

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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Install \(plugin.name)"))
                }

                if validatedExternalURL(detailsURLString) != nil {
                    Button {
                        onOpenDetails()
                    } label: {
                        Label(localizedAppText("Details", de: "Details"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText("Open details for \(plugin.name)", de: "Details für \(plugin.name) öffnen", ja: "\(plugin.name)の詳細を開く"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
