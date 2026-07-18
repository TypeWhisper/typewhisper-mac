import SwiftUI
import AppKit
import TypeWhisperPluginSDK

enum SettingsTab: Hashable {
    case home, general, dictation, hotkeys, recorder
    case dictationRecovery, fileTranscription, history, statistics, dictionary, snippets, workflows, profiles, prompts, premium, integrations, advanced, license, about
}

private struct SettingsDestination: Identifiable, Hashable {
    let tab: SettingsTab
    let title: String
    let systemImage: String
    let badge: Int?

    var id: SettingsTab { tab }
}

private struct SettingsDestinationSection: Identifiable {
    let id: String
    let destinations: [SettingsDestination]
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = FileTranscriptionViewModel.shared
    @ObservedObject private var dictationRecovery = DictationRecoveryViewModel.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var homeViewModel = HomeViewModel.shared
    @ObservedObject private var promptActionsViewModel = PromptActionsViewModel.shared
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared

    private var destinations: [SettingsDestination] {
        [
            SettingsDestination(tab: .home, title: String(localized: "Home"), systemImage: "house", badge: nil),
            SettingsDestination(tab: .general, title: String(localized: "General"), systemImage: "gear", badge: nil),
            SettingsDestination(tab: .dictation, title: String(localized: "Dictation"), systemImage: "mic.fill", badge: nil),
            SettingsDestination(tab: .hotkeys, title: String(localized: "Hotkeys"), systemImage: "keyboard", badge: nil),
            SettingsDestination(
                tab: .recorder,
                title: String(localized: "settings.tab.recorder"),
                systemImage: "waveform.circle",
                badge: nil
            ),
            SettingsDestination(
                tab: .dictationRecovery,
                title: localizedAppText("Recovery", de: "Wiederherstellung"),
                systemImage: "waveform",
                badge: nil
            ),
            SettingsDestination(tab: .fileTranscription, title: String(localized: "File Transcription"), systemImage: "doc.text", badge: nil),
            SettingsDestination(tab: .history, title: String(localized: "History"), systemImage: "clock.arrow.circlepath", badge: nil),
            SettingsDestination(
                tab: .statistics,
                title: String(localized: "Statistics"),
                systemImage: "chart.bar.xaxis",
                badge: nil
            ),
            SettingsDestination(tab: .dictionary, title: String(localized: "Dictionary"), systemImage: "book.closed", badge: nil),
            SettingsDestination(tab: .snippets, title: String(localized: "Snippets"), systemImage: "text.badge.plus", badge: nil),
            SettingsDestination(
                tab: .workflows,
                title: localizedAppText("Workflows", de: "Workflows"),
                systemImage: "point.3.connected.trianglepath.dotted",
                badge: nil
            ),
            SettingsDestination(
                tab: .premium,
                title: localizedAppText("Premium", de: "Premium"),
                systemImage: "sparkles",
                badge: nil
            ),
            SettingsDestination(
                tab: .integrations,
                title: String(localized: "Integrations"),
                systemImage: "puzzlepiece.extension",
                badge: registryService.availableUpdatesCount > 0 ? registryService.availableUpdatesCount : nil
            ),
            SettingsDestination(tab: .advanced, title: String(localized: "Advanced"), systemImage: "gearshape.2", badge: nil),
            SettingsDestination(tab: .license, title: String(localized: "License"), systemImage: "key", badge: nil),
            SettingsDestination(tab: .about, title: String(localized: "About"), systemImage: "info.circle", badge: nil)
        ].compactMap { $0 }
    }

    private var destinationSections: [SettingsDestinationSection] {
        settingsDestinationSections(destinations)
    }

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                SettingsModernShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: { tab in AnyView(settingsDetail(for: tab)) }
                )
            } else {
                SettingsSidebarShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: settingsDetail(for:)
                )
            }
        }
        .frame(minWidth: 950, idealWidth: 1050, minHeight: 550, idealHeight: 600)
        .onAppear {
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: fileTranscription.showFilePickerFromMenu) { _, _ in
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: homeViewModel.navigateToHistory) { _, navigate in
            if navigate {
                selectedTab = .history
                homeViewModel.navigateToHistory = false
            }
        }
        .onChange(of: homeViewModel.navigateToStatistics) { _, navigate in
            if navigate {
                selectedTab = .statistics
                homeViewModel.navigateToStatistics = false
            }
        }
        .onChange(of: promptActionsViewModel.navigateToIntegrations) { _, navigate in
            if navigate {
                selectedTab = .integrations
                promptActionsViewModel.navigateToIntegrations = false
            }
        }
        .onReceive(settingsNavigation.$request.compactMap { $0 }) { request in
            switch request.tab {
            case .profiles, .prompts, .workflows:
                selectedTab = .workflows
                WorkflowsNavigationCoordinator.shared.showMine()
            default:
                selectedTab = Self.availableTab(request.tab)
            }
        }
    }

    static func availableTab(_ tab: SettingsTab) -> SettingsTab {
        tab
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .home:
            HomeSettingsView()
        case .general:
            GeneralSettingsView()
        case .dictation:
            RecordingSettingsView()
        case .hotkeys:
            HotkeySettingsView()
        case .recorder:
            AudioRecorderView(viewModel: AudioRecorderViewModel.shared)
        case .dictationRecovery:
            DictationRecoveryView()
        case .fileTranscription:
            FileTranscriptionView()
        case .history:
            HistoryView()
        case .statistics:
            StatisticsView()
        case .dictionary:
            DictionarySettingsView()
        case .snippets:
            SnippetsSettingsView()
        case .workflows:
            WorkflowsSettingsView()
        case .profiles:
            WorkflowsSettingsView()
        case .prompts:
            WorkflowsSettingsView()
        case .premium:
            PremiumSettingsView()
        case .integrations:
            PluginSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .license:
            LicenseSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

@available(macOS 15, *)
private struct SettingsModernShell: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> AnyView

    @State private var sidebarSearchText = ""
    @State private var isSidebarVisible = true

    var body: some View {
        SettingsSplitView(
            selectedTab: $selectedTab,
            sidebarSearchText: $sidebarSearchText,
            sections: sections,
            isSidebarVisible: $isSidebarVisible,
            detail: detail
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { isSidebarVisible.toggle() }) {
                    Image(systemName: "sidebar.leading")
                }
                .help(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
                .accessibilityLabel(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
            }
        }
    }
}

// Bridges to a native AppKit NSSplitViewController rather than SwiftUI's
// NavigationSplitView or a hand-rolled HStack. Three prior pure-SwiftUI attempts
// each fixed one property at the cost of another:
//   - NavigationSplitView: resize is fluid (native), but its built-in collapse
//     animation reflows row labels frame-by-frame — a visible glitch on this
//     macOS version.
//   - Custom HStack + zero-duration toggle: fixed the glitch, but the divider
//     and sidebar content could pop out of sync with each other.
//   - Custom HStack + live @GestureState width: fixed the sync issue, but
//     SwiftUI's List (backed by NSTableView) can't relayout at pointer-tracking
//     speed, so rows visibly lag behind the resizing frame during a live drag.
// NSSplitViewController is the actual mechanism Finder/Mail/Notes use for their
// sidebars — it owns both resize and collapse natively, so neither is fighting
// a SwiftUI layout pass, and VoiceOver/keyboard resize support comes for free.
@available(macOS 15, *)
private struct SettingsSplitView: NSViewControllerRepresentable {
    @Binding var selectedTab: SettingsTab
    @Binding var sidebarSearchText: String
    let sections: [SettingsDestinationSection]
    @Binding var isSidebarVisible: Bool
    let detail: (SettingsTab) -> AnyView

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitViewController = NSSplitViewController()
        splitViewController.splitView.dividerStyle = .thin

        let sidebarHostingController = NSHostingController(
            rootView: SettingsSidebarContent(
                selectedTab: $selectedTab,
                sidebarSearchText: $sidebarSearchText,
                sections: sections
            )
        )
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHostingController)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !isSidebarVisible

        let detailHostingController = NSHostingController(
            rootView: AnyView(
                detail(selectedTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
        )
        let detailItem = NSSplitViewItem(viewController: detailHostingController)

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)

        context.coordinator.sidebarItem = sidebarItem
        context.coordinator.sidebarHostingController = sidebarHostingController
        context.coordinator.detailHostingController = detailHostingController
        context.coordinator.isSidebarVisible = $isSidebarVisible
        // The user can collapse the sidebar natively — dragging the divider past
        // its minimum thickness, or double-clicking it — without going through
        // our toolbar button at all. Without this observer, isSidebarVisible
        // never learns about it, so the button's next click just re-asserts the
        // (already collapsed) state as a no-op, requiring a second click to
        // actually reopen it.
        context.coordinator.observeCollapseState(of: sidebarItem)

        return splitViewController
    }

    func updateNSViewController(_ splitViewController: NSSplitViewController, context: Context) {
        context.coordinator.sidebarHostingController?.rootView = SettingsSidebarContent(
            selectedTab: $selectedTab,
            sidebarSearchText: $sidebarSearchText,
            sections: sections
        )
        context.coordinator.detailHostingController?.rootView = AnyView(
            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        context.coordinator.isSidebarVisible = $isSidebarVisible

        guard let sidebarItem = context.coordinator.sidebarItem else { return }
        let shouldBeCollapsed = !isSidebarVisible
        guard sidebarItem.isCollapsed != shouldBeCollapsed else { return }

        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.2
            animationContext.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed = shouldBeCollapsed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var sidebarItem: NSSplitViewItem?
        var sidebarHostingController: NSHostingController<SettingsSidebarContent>?
        var detailHostingController: NSHostingController<AnyView>?
        var isSidebarVisible: Binding<Bool>?
        private var collapseObservation: NSKeyValueObservation?

        // Captures the binding itself rather than `self` — `Coordinator` is a
        // plain (non-Sendable) class, and KVO's changeHandler is `@Sendable`, so
        // capturing `self` (even weakly) to reach `self.isSidebarVisible` trips
        // Swift 6 strict concurrency checking. The binding's identity is stable
        // for the representable's lifetime, so a snapshot at observation time
        // stays valid.
        func observeCollapseState(of sidebarItem: NSSplitViewItem) {
            let isSidebarVisible = isSidebarVisible
            collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { _, change in
                guard let isCollapsed = change.newValue else { return }
                let shouldBeVisible = !isCollapsed
                if isSidebarVisible?.wrappedValue != shouldBeVisible {
                    isSidebarVisible?.wrappedValue = shouldBeVisible
                }
            }
        }
    }
}

private struct SettingsSidebarContent: View {
    @Binding var selectedTab: SettingsTab
    @Binding var sidebarSearchText: String
    let sections: [SettingsDestinationSection]

    private var filteredSections: [SettingsDestinationSection] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }

        return sections
            .map { section in
                SettingsDestinationSection(
                    id: section.id,
                    destinations: section.destinations.filter { destination in
                        destination.title.localizedCaseInsensitiveContains(query)
                    }
                )
            }
            .filter { !$0.destinations.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchField(text: $sidebarSearchText)

            List(selection: $selectedTab) {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.destinations) { destination in
                            SettingsSidebarRow(destination: destination)
                                .tag(destination.tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Changing the section/row count via search filtering can leave stale,
            // blank space behind from SwiftUI's incremental List diffing. Keying the
            // List on the query forces a clean rebuild instead of a partial diff.
            .id(sidebarSearchText)
        }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                localizedAppText("Search Settings", de: "Einstellungen durchsuchen"),
                text: $text
            )
            .textFieldStyle(.plain)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(localizedAppText("Clear Search", de: "Suche löschen"))
                .accessibilityLabel(localizedAppText("Clear Search", de: "Suche löschen"))
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
    }
}

private func settingsDestination(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination {
    destinations.first(where: { $0.tab == tab })!
}

private func settingsDestinationIfAvailable(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination? {
    destinations.first(where: { $0.tab == tab })
}

private func settingsTitle(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).title
}

private func settingsSystemImage(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).systemImage
}

private func settingsBadge(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> Int? {
    settingsDestination(destinations, tab).badge
}

private func settingsDestinationSections(_ destinations: [SettingsDestination]) -> [SettingsDestinationSection] {
    var coreDestinations = [
        settingsDestination(destinations, .general),
        settingsDestination(destinations, .dictation)
    ]
    if let recoveryDestination = settingsDestinationIfAvailable(destinations, .dictationRecovery) {
        coreDestinations.append(recoveryDestination)
    }
    coreDestinations.append(contentsOf: [
        settingsDestination(destinations, .hotkeys),
        settingsDestination(destinations, .fileTranscription),
        settingsDestination(destinations, .recorder)
    ])

    var workspaceDestinations = [
        settingsDestination(destinations, .history),
        settingsDestination(destinations, .statistics),
        settingsDestination(destinations, .dictionary),
        settingsDestination(destinations, .snippets),
        settingsDestination(destinations, .workflows),
        settingsDestination(destinations, .premium)
    ]

    workspaceDestinations.append(settingsDestination(destinations, .integrations))

    return [
        SettingsDestinationSection(
            id: "home",
            destinations: [settingsDestination(destinations, .home)]
        ),
        SettingsDestinationSection(
            id: "core",
            destinations: coreDestinations
        ),
        SettingsDestinationSection(
            id: "workspace",
            destinations: workspaceDestinations
        ),
        SettingsDestinationSection(
            id: "system",
            destinations: [
                settingsDestination(destinations, .advanced),
                settingsDestination(destinations, .license),
                settingsDestination(destinations, .about)
            ]
        )
    ]
}

private struct SettingsSidebarShell<DetailContent: View>: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> DetailContent

    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                List(selection: $selectedTab) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.destinations) { destination in
                                SettingsSidebarRow(destination: destination)
                                    .tag(destination.tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)

                Divider()
            }

            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // macOS 14 glitches when the default NavigationSplitView sidebar reveal animates.
        // Use a custom zero-duration toggle instead.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
                .accessibilityLabel(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
            }
        }
    }

    private func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withAnimation(nil) {
                isSidebarVisible.toggle()
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let destination: SettingsDestination

    var body: some View {
        HStack(spacing: 10) {
            Label(destination.title, systemImage: destination.systemImage)

            Spacer(minLength: 8)

            if let badge = destination.badge {
                SettingsSidebarBadge(title: destination.title, count: badge)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsSidebarBadge: View {
    let title: String
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title), \(count) updates")
    }
}

struct RecordingSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var settings = SettingsViewModel.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @State private var selectedProvider: String?
    @State private var customSounds: [String] = SoundChoice.installedCustomSounds()
    @State private var draggedInputDevicePriorityItem: AudioInputDevicePriorityItem?
    private let soundService = ServiceContainer.shared.soundService

    private var needsPermissions: Bool {
        dictation.needsMicPermission || dictation.needsAccessibilityPermission
    }

    private func transcriptionAuthNotice(for engines: [TranscriptionEnginePlugin]) -> String? {
        engines
            .map { modelManager.transcriptionAuthStatus(for: $0) }
            .first { !$0.isAvailable }?
            .unavailableReason
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: TranscriptionEnginePlugin) -> some View {
        let authStatus = modelManager.transcriptionAuthStatus(for: engine)
        HStack {
            Text(engine.providerDisplayName)
            if !authStatus.isAvailable {
                Text("(\(String(localized: "unavailable")))")
                    .foregroundStyle(.secondary)
            } else if !engine.isConfigured {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inputDeviceSelectionBinding: Binding<String?> {
        Binding(
            get: { audioDevice.selectedDeviceUID },
            set: { newValue in
                if let newValue {
                    audioDevice.selectInputDeviceAsPrimary(newValue)
                } else {
                    audioDevice.clearInputDevicePriorityList()
                }
            }
        )
    }

    @ViewBuilder
    private var microphonePriorityEditor: some View {
        if shouldShowMicrophonePriorityList {
            LabeledContent(String(localized: "Microphone Priority")) {
                VStack(alignment: .trailing, spacing: 6) {
                    microphonePriorityList
                        .frame(maxWidth: 560, alignment: .leading)

                    microphonePriorityAddMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack {
                Spacer()
                microphonePriorityAddMenu
            }
        }
    }

    private var shouldShowMicrophonePriorityList: Bool {
        let priorityList = audioDevice.inputDevicePriorityList
        guard priorityList.count == 1, let item = priorityList.first else {
            return priorityList.count > 1
        }

        return !audioDevice.isInputDevicePriorityItemAvailable(item)
    }

    @ViewBuilder
    private var microphonePriorityList: some View {
        if !audioDevice.inputDevicePriorityList.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(audioDevice.inputDevicePriorityList.enumerated()), id: \.element.id) { index, item in
                    microphonePriorityRow(index: index, item: item)
                        .onDrag {
                            draggedInputDevicePriorityItem = item
                            return NSItemProvider(object: item.uid as NSString)
                        }
                        .onDrop(
                            of: ["public.text"],
                            delegate: MicrophonePriorityDropDelegate(
                                item: item,
                                audioDevice: audioDevice,
                                draggedItem: $draggedInputDevicePriorityItem
                            )
                        )

                    if index < audioDevice.inputDevicePriorityList.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
        }
    }

    private var microphonePriorityAddMenu: some View {
        Menu {
            if audioDevice.inputDevicePriorityCandidates.isEmpty {
                Text(String(localized: "No more microphones"))
            } else {
                ForEach(audioDevice.inputDevicePriorityCandidates) { device in
                    Button(audioDevice.displayName(for: device)) {
                        audioDevice.addInputDeviceToPriorityList(device)
                    }
                }
            }
        } label: {
            Label(String(localized: "Add Microphone"), systemImage: "plus")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help(String(localized: "Add Microphone"))
    }

    private func microphonePriorityRow(index: Int, item: AudioInputDevicePriorityItem) -> some View {
        let isAvailable = audioDevice.isInputDevicePriorityItemAvailable(item)
        let canMoveUp = index > 0
        let canMoveDown = index < audioDevice.inputDevicePriorityList.count - 1

        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12)

            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            Text(audioDevice.displayName(for: item))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            if !isAvailable {
                Text(String(localized: "Disconnected"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button {
                audioDevice.removeInputDevicePriorityItem(item)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            .help(String(localized: "Remove microphone"))
        }
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                moveMicrophonePriorityItemUp(item)
            } label: {
                Label(String(localized: "Move Up"), systemImage: "chevron.up")
            }
            .disabled(!canMoveUp)

            Button {
                moveMicrophonePriorityItemDown(item)
            } label: {
                Label(String(localized: "Move Down"), systemImage: "chevron.down")
            }
            .disabled(!canMoveDown)
        }
        .modifier(MicrophonePriorityAccessibilityActions(
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            moveUp: { moveMicrophonePriorityItemUp(item) },
            moveDown: { moveMicrophonePriorityItemDown(item) }
        ))
    }

    private func moveMicrophonePriorityItemUp(_ item: AudioInputDevicePriorityItem) {
        guard let index = audioDevice.inputDevicePriorityList.firstIndex(of: item),
              index > 0 else { return }

        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: index), to: index - 1)
    }

    private func moveMicrophonePriorityItemDown(_ item: AudioInputDevicePriorityItem) {
        guard let index = audioDevice.inputDevicePriorityList.firstIndex(of: item),
              index < audioDevice.inputDevicePriorityList.count - 1 else { return }

        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: index), to: index + 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Dictation"))
            Divider()

            Form {
                if needsPermissions {
                    PermissionsBanner(dictation: dictation)
                }

                Section(String(localized: "Spoken Language")) {
                LanguageSelectionEditor(
                    selection: $settings.languageSelection,
                    availableLanguages: settings.availableLanguages,
                    hintBehavior: LanguageSelectionHintBehavior(engine: settings.activeTranscriptionEngine)
                )

                Text(String(localized: "Controls push-to-talk dictation, workflows that inherit the global spoken language, and CLI/API defaults when they use app defaults. Recorder and Recovery have separate language settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                Section(String(localized: "Engine")) {
                let engines = pluginManager.transcriptionEngines
                if engines.isEmpty {
                    Text(String(localized: "No transcription engines installed. Install engines via Integrations."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Default Engine"), selection: $selectedProvider) {
                        Text(String(localized: "None")).tag(nil as String?)
                        Divider()
                        ForEach(engines, id: \.providerId) { engine in
                            enginePickerLabel(for: engine)
                                .tag(engine.providerId as String?)
                                .disabled(!modelManager.canUseForTranscription(engine))
                        }
                    }
                    .onChange(of: selectedProvider) { _, newValue in
                        if let newValue {
                            modelManager.selectProvider(newValue)
                        }
                    }

                    if let notice = transcriptionAuthNotice(for: engines) {
                        Label(notice, systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let providerId = selectedProvider,
                       let engine = pluginManager.transcriptionEngine(for: providerId),
                       modelManager.canUseForTranscription(engine) {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: Binding(
                                get: { engine.selectedModelId },
                                set: { if let id = $0 { modelManager.selectModel(providerId, modelId: id) } }
                            )) {
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                        }
                    }

                }
            }

                Section(String(localized: "Microphone")) {
                Picker(String(localized: "Input Device"), selection: inputDeviceSelectionBinding) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(audioDevice.displayName(for: device)).tag(device.uid as String?)
                    }
                }

                microphonePriorityEditor

                if let message = audioDevice.selectedDeviceStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        AudioWaveformView(
                            audioLevel: audioDevice.previewAudioLevel,
                            isSetup: false,
                            compact: true
                        )
                        .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .disabled(!audioDevice.isPreviewActive && dictation.needsMicPermission)

                if let error = audioDevice.previewError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let name = audioDevice.disconnectedDeviceName {
                    Label(
                        String(localized: "Microphone disconnected. Falling back to system default."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if audioDevice.disconnectedDeviceName == name {
                                audioDevice.disconnectedDeviceName = nil
                            }
                        }
                    }
                }
            }

                Section(String(localized: "Sound")) {
                Toggle(String(localized: "Play sound feedback"), isOn: $dictation.soundFeedbackEnabled)

                if dictation.soundFeedbackEnabled {
                    SoundEventPicker(event: .recordingStarted, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .transcriptionSuccess, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .error, soundService: soundService, customSounds: $customSounds)
                }

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

                Section(String(localized: "Clipboard")) {
                Toggle(String(localized: "Preserve clipboard content"), isOn: $dictation.preserveClipboard)

                Text(String(localized: "Restores your clipboard after text insertion. Without this, your clipboard contains the transcribed text after dictation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                Section(String(localized: "Output Formatting")) {
                Toggle(String(localized: "App-aware formatting"), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled) },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.appFormattingEnabled) }
                ))

                Text(String(localized: "When enabled, TypeWhisper uses target-app rules and available cursor context for smarter insertion. Workflow output format settings still choose the inserted format for each workflow."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "Normalize spoken numbers to digits"), isOn: Binding(
                    get: { TranscriptionNormalizationService.numberNormalizationEnabled() },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) }
                ))

                Text(String(localized: "Converts spoken numbers in supported languages into digits before insertion and export."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                Section(String(localized: "Audio Ducking")) {
                Toggle(String(localized: "Reduce system volume during recording"), isOn: $dictation.audioDuckingEnabled)

                if dictation.audioDuckingEnabled {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .foregroundStyle(.secondary)
                        Slider(value: $dictation.audioDuckingLevel, in: 0...0.5, step: 0.05)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Percentage of your current volume to use during recording. 0% mutes completely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

                Section(String(localized: "Media Pause")) {
                Toggle(String(localized: "Pause media playback during recording"), isOn: $dictation.mediaPauseEnabled)

                Text(String(localized: "Automatically pauses music and videos while recording and resumes when done. Uses macOS system media controls - may not work with all apps."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                if needsPermissions {
                    Section(String(localized: "Permissions")) {
                    if dictation.needsMicPermission {
                        HStack {
                            Label(
                                String(localized: "Microphone"),
                                systemImage: "mic.slash"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestMicPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if dictation.needsAccessibilityPermission {
                        HStack {
                            Label(
                                String(localized: "Accessibility"),
                                systemImage: "lock.shield"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            modelManager.restoreProviderSelection()
            selectedProvider = modelManager.selectedProviderId
            customSounds = SoundChoice.installedCustomSounds()
        }
    }

}

// MARK: - Sound Event Picker

private struct SoundEventPicker: View {
    let event: SoundEvent
    let soundService: SoundService
    @Binding var customSounds: [String]
    @State private var selection: String

    init(event: SoundEvent, soundService: SoundService, customSounds: Binding<[String]>) {
        self.event = event
        self.soundService = soundService
        self._customSounds = customSounds
        self._selection = State(initialValue: soundService.choice(for: event).storageKey)
    }

    var body: some View {
        HStack {
            Picker(event.displayName, selection: $selection) {
                Text(String(localized: "Default")).tag(event.defaultChoice.storageKey)

                Divider()

                ForEach(SoundChoice.bundledSounds, id: \.name) { sound in
                    Text(sound.displayName).tag(SoundChoice.bundled(sound.name).storageKey)
                }

                if !customSounds.isEmpty {
                    Divider()
                    ForEach(customSounds, id: \.self) { name in
                        Text(name).tag(SoundChoice.custom(name).storageKey)
                    }
                }

                Divider()

                ForEach(SoundChoice.systemSounds, id: \.self) { name in
                    Text(name).tag(SoundChoice.system(name).storageKey)
                }

                Divider()

                Text(String(localized: "None")).tag(SoundChoice.none.storageKey)
            }
            .onChange(of: selection) { _, newValue in
                let choice = SoundChoice(storageKey: newValue)
                soundService.updateChoice(for: event, choice: choice)
                soundService.preview(choice)
            }

            Button {
                soundService.preview(SoundChoice(storageKey: selection))
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Preview sound"))

            Button {
                importCustomSound()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Add custom sound"))
        }
    }

    private func importCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundChoice.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a sound file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try soundService.importCustomSound(from: url)
            customSounds = SoundChoice.installedCustomSounds()
            selection = SoundChoice.custom(filename).storageKey
        } catch {
            // File copy failed - silently ignore
        }
    }
}

private struct MicrophonePriorityAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp && canMoveDown {
            content
                .accessibilityAction(named: Text(String(localized: "Move Up")), moveUp)
                .accessibilityAction(named: Text(String(localized: "Move Down")), moveDown)
        } else if canMoveUp {
            content
                .accessibilityAction(named: Text(String(localized: "Move Up")), moveUp)
        } else if canMoveDown {
            content
                .accessibilityAction(named: Text(String(localized: "Move Down")), moveDown)
        } else {
            content
        }
    }
}

private struct MicrophonePriorityDropDelegate: DropDelegate {
    let item: AudioInputDevicePriorityItem
    let audioDevice: AudioDeviceService
    @Binding var draggedItem: AudioInputDevicePriorityItem?

    func dropEntered(info: DropInfo) {
        guard let draggedItem,
              draggedItem != item,
              let fromIndex = audioDevice.inputDevicePriorityList.firstIndex(of: draggedItem),
              let toIndex = audioDevice.inputDevicePriorityList.firstIndex(of: item) else { return }

        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        audioDevice.moveInputDevicePriorityItems(from: IndexSet(integer: fromIndex), to: destination)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

// MARK: - Permissions Banner

struct PermissionsBanner: View {
    @ObservedObject var dictation: DictationViewModel

    var body: some View {
        Section {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
