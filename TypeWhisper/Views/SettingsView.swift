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
    @State private var sidebarWidth: CGFloat = 270
    @State private var previewWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?
    @State private var isResizeHandleHovering = false
    @FocusState private var isSearchFieldFocused: Bool

    private let minSidebarWidth: CGFloat = 240
    private let maxSidebarWidth: CGFloat = 320
    private let resizeStep: CGFloat = 20

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
        HStack(spacing: 0) {
            // Collapsing removes the sidebar from the view tree entirely (rather than
            // zeroing/clipping a frame while it stays mounted), so a hidden sidebar is
            // automatically unreachable by keyboard focus, VoiceOver, and hit-testing —
            // no manual .disabled/.accessibilityHidden bookkeeping needed. The slide
            // transition uses an offset transform rather than animating width, so row
            // labels never reflow/truncate mid-toggle the way NavigationSplitView's
            // built-in width-based collapse animation does.
            if isSidebarVisible {
                // Grouped so the sidebar and its resize handle slide out together as
                // one rigid unit. Giving them separate .transition() instances left the
                // handle behind mid-collapse: .move only offsets a view's rendering
                // without changing siblings' HStack layout math, so once the sidebar's
                // slot was removed from layout the handle's position snapped instantly
                // to its new (sidebar-less) spot while its own opacity fade was still
                // playing — a stray line hanging over the detail pane for the last
                // fraction of the animation.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        SettingsSidebarSearchField(text: $sidebarSearchText, isFocused: $isSearchFieldFocused)

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
                    // sidebarWidth only ever changes on drag release (see
                    // SettingsSidebarResizeHandle), not on every pointer-move frame, so
                    // the List doesn't relayout continuously during a drag — relaying
                    // out its native NSScroller-backed rows on every frame was the
                    // source of the resize lag. A thin guide line tracks the pointer
                    // instead; the real resize commits once when the drag ends.
                    .frame(width: sidebarWidth)

                    SettingsSidebarResizeHandle(
                        committedWidth: sidebarWidth,
                        sidebarWidth: $sidebarWidth,
                        previewWidth: $previewWidth,
                        dragStartWidth: $dragStartWidth,
                        isHovering: $isResizeHandleHovering,
                        minWidth: minSidebarWidth,
                        maxWidth: maxSidebarWidth,
                        step: resizeStep
                    )
                }
                .transition(.move(edge: .leading))
            }

            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.easeInOut(duration: 0.22), value: isSidebarVisible)
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

private struct SettingsSidebarResizeHandle: View {
    let committedWidth: CGFloat
    @Binding var sidebarWidth: CGFloat
    @Binding var previewWidth: CGFloat?
    @Binding var dragStartWidth: CGFloat?
    @Binding var isHovering: Bool
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let step: CGFloat

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    // Pop the cursor unconditionally if this view disappears (e.g. the
                    // sidebar collapses) while still hovered — onHover's "false" event
                    // does not reliably fire when the view is removed from the tree
                    // mid-hover, which would otherwise leave the resize cursor stuck.
                    .onDisappear {
                        if isHovering {
                            NSCursor.pop()
                            isHovering = false
                        }
                        previewWidth = nil
                        dragStartWidth = nil
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = dragStartWidth ?? committedWidth
                                dragStartWidth = base
                                previewWidth = min(max(base + value.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in
                                if let previewWidth {
                                    sidebarWidth = previewWidth
                                }
                                previewWidth = nil
                                dragStartWidth = nil
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel(localizedAppText("Sidebar Width", de: "Seitenleistenbreite"))
                    .accessibilityValue("\(Int(sidebarWidth)) pt")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            sidebarWidth = min(sidebarWidth + step, maxWidth)
                        case .decrement:
                            sidebarWidth = max(sidebarWidth - step, minWidth)
                        @unknown default:
                            break
                        }
                    }
            )
            // Cheap: a single thin rectangle offset from the divider's actual
            // position, not a relayout of anything. Gives live feedback about where
            // the sidebar would land without touching the List during the drag.
            // Always mounted (never conditionally inserted/removed) so it fades out
            // in step with the drag ending instead of vanishing instantly — same
            // reasoning as the sidebar's own opacity-faded divider.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: (previewWidth ?? committedWidth) - committedWidth)
                    .opacity(previewWidth == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: previewWidth == nil)
            }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                localizedAppText("Search Settings", de: "Einstellungen durchsuchen"),
                text: $text
            )
            .textFieldStyle(.plain)
            .focused(isFocused)

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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
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
        .padding()
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
