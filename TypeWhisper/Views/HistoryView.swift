import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var viewModel = HistoryViewModel.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var deleteCandidateIDs: Set<UUID> = []
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } content: {
            recordList
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HistoryWindowCloseGuard(viewModel: viewModel))
        .searchable(
            text: $viewModel.searchQuery,
            placement: .toolbar,
            prompt: String(localized: "Search History")
        )
        .toolbar { workspaceToolbar }
        .alert(
            String(localized: "Save Changes?"),
            isPresented: unsavedChangesBinding
        ) {
            Button(String(localized: "Save")) {
                viewModel.saveAndContinue()
            }
            .disabled(!viewModel.canSaveDraft)
            Button(String(localized: "Discard"), role: .destructive) {
                viewModel.discardAndContinue()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                viewModel.cancelPendingTransition()
            }
        } message: {
            Text(String(localized: "Save or discard your changes before leaving this entry."))
        }
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                deleteRecords(with: deleteCandidateIDs)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteConfirmationMessage)
        }
        .onChange(of: viewModel.pendingDeletionIDs) { _, ids in
            guard !ids.isEmpty else { return }
            deleteCandidateIDs = ids
            showingDeleteConfirmation = true
            viewModel.consumePendingDeletion()
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var unsavedChangesBinding: Binding<Bool> {
        Binding {
            viewModel.showsUnsavedChangesPrompt
        } set: { _ in }
    }

    private var recordSelection: Binding<Set<UUID>> {
        Binding {
            viewModel.selectedRecordIDs
        } set: { selection in
            viewModel.requestRecordSelection(selection)
        }
    }

    private var sidebar: some View {
        List {
            Section(String(localized: "Smart Mailboxes")) {
                ForEach(HistoryCollectionScope.allCases) { mailbox in
                    sidebarButton(
                        title: mailbox.displayName,
                        systemImage: mailbox.systemImage,
                        count: viewModel.count(for: mailbox),
                        selection: .smartMailbox(mailbox)
                    )
                }
            }

            Section(String(localized: "Devices")) {
                ForEach(viewModel.deviceSections) { device in
                    deviceGroup(device)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "History"))
    }

    @ViewBuilder
    private func deviceGroup(_ device: HistoryDeviceSection) -> some View {
        if device.sources.isEmpty {
            sidebarButton(
                title: device.title,
                systemImage: device.systemImage,
                count: device.count,
                selection: .device(device.id)
            )
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { viewModel.expandedDeviceIDs.contains(device.id) },
                    set: { expanded in
                        let isExpanded = viewModel.expandedDeviceIDs.contains(device.id)
                        if expanded != isExpanded {
                            viewModel.toggleDeviceExpansion(device.id)
                        }
                    }
                )
            ) {
                ForEach(device.sources) { source in
                    sidebarButton(
                        title: source.title,
                        systemImage: source.systemImage,
                        count: source.count,
                        selection: .deviceSource(deviceID: device.id, source: source.source)
                    )
                }
            } label: {
                sidebarButtonLabel(
                    title: device.title,
                    systemImage: device.systemImage,
                    count: device.count
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.requestNavigationSelection(.device(device.id))
                }
            }
            .listRowBackground(
                viewModel.navigationSelection == .device(device.id)
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear
            )
        }
    }

    private func sidebarButton(
        title: String,
        systemImage: String,
        count: Int,
        selection: HistoryNavigationSelection
    ) -> some View {
        Button {
            viewModel.requestNavigationSelection(selection)
        } label: {
            sidebarButtonLabel(title: title, systemImage: systemImage, count: count)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            viewModel.navigationSelection == selection
                ? Color.accentColor.opacity(0.16)
                : Color.clear
        )
    }

    private func sidebarButtonLabel(title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 {
                Text(count, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recordList: some View {
        Group {
            if viewModel.filteredRecords.isEmpty {
                emptyListState
            } else {
                List(selection: recordSelection) {
                    ForEach(viewModel.groupedSections) { section in
                        Section {
                            if !viewModel.collapsedGroups.contains(section.group) {
                                ForEach(section.records, id: \.id) { record in
                                    HistoryRecordRow(record: record)
                                        .tag(record.id)
                                        .contextMenu { recordContextMenu(for: record) }
                                }
                            }
                        } header: {
                            HistorySectionHeader(
                                group: section.group,
                                count: section.records.count,
                                isCollapsed: viewModel.collapsedGroups.contains(section.group)
                            ) {
                                viewModel.toggleSection(section.group)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .id(viewModel.navigationSelection)
            }
        }
        .navigationTitle(viewModel.navigationTitle)
        .navigationSubtitle(viewModel.navigationSummary)
    }

    @ViewBuilder
    private var emptyListState: some View {
        if !viewModel.searchQuery.isEmpty || viewModel.hasActiveFilters {
            ContentUnavailableView {
                Label(String(localized: "No Results"), systemImage: "magnifyingglass")
            } description: {
                Text(String(localized: "No history entries match the current search and filters."))
            } actions: {
                Button(String(localized: "Clear Filters")) {
                    viewModel.requestClearAllFilters()
                }
            }
        } else if viewModel.selectedSmartMailbox == .inbox {
            ContentUnavailableView(
                String(localized: "Inbox is Empty"),
                systemImage: "tray",
                description: Text(String(localized: "New captures that need attention will appear here."))
            )
        } else if viewModel.selectedSmartMailbox == .failed {
            ContentUnavailableView(
                String(localized: "No Failed Entries"),
                systemImage: "checkmark.circle",
                description: Text(String(localized: "Failed imports and transcriptions will appear here."))
            )
        } else {
            ContentUnavailableView(
                String(localized: "No History Yet"),
                systemImage: "clock.arrow.circlepath",
                description: Text(String(localized: "Your saved transcriptions will appear here."))
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if viewModel.selectedRecordIDs.count > 1 {
            ContentUnavailableView {
                Label(
                    String.localizedStringWithFormat(
                        String(localized: "%lld Entries Selected"),
                        Int64(viewModel.selectedRecordIDs.count)
                    ),
                    systemImage: "checkmark.circle"
                )
            } description: {
                Text(String(localized: "Copy, export, complete, reopen, or delete the selected entries."))
            } actions: {
                HStack {
                    Button(String(localized: "Copy")) { viewModel.copySelectedRecords() }
                    if viewModel.selectedRecords.contains(where: \.isOpenInInbox) {
                        Button(String(localized: "Mark Complete")) {
                            viewModel.markComplete(viewModel.selectedRecords)
                        }
                    }
                }
            }
        } else if let record = viewModel.selectedRecord {
            HistoryRecordDetailView(record: record, viewModel: viewModel)
                .id(record.id)
        } else {
            ContentUnavailableView(
                String(localized: "Select an Entry"),
                systemImage: "text.page",
                description: Text(String(localized: "Choose an entry to read and edit its text or inspect its details."))
            )
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker(
                    String(localized: "Date"),
                    selection: Binding(
                        get: { viewModel.selectedTimeRange },
                        set: { viewModel.requestTimeRange($0) }
                    )
                ) {
                    ForEach(HistoryTimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }

                Menu(String(localized: "App")) {
                    Button {
                        viewModel.requestAppFilter(nil)
                    } label: {
                        filterMenuLabel(
                            String(localized: "All Apps"),
                            selected: viewModel.selectedAppFilter == nil
                        )
                    }
                    Divider()
                    ForEach(viewModel.availableApps) { app in
                        Button {
                            viewModel.requestAppFilter(app.bundleId)
                        } label: {
                            filterMenuLabel(
                                app.name,
                                selected: viewModel.selectedAppFilter == app.bundleId
                            )
                        }
                    }
                }

                if viewModel.hasActiveFilters || !viewModel.searchQuery.isEmpty {
                    Divider()
                    Button(String(localized: "Clear Filters")) {
                        viewModel.requestClearAllFilters()
                    }
                }
            } label: {
                Label(String(localized: "Filter"), systemImage: "line.3.horizontal.decrease")
            }
            .help(String(localized: "Filter History"))

            Menu {
                ForEach(HistorySortOrder.allCases) { order in
                    Button {
                        viewModel.requestSortOrder(order)
                    } label: {
                        if viewModel.selectedSortOrder == order {
                            Label(order.displayName, systemImage: "checkmark")
                        } else {
                            Text(order.displayName)
                        }
                    }
                }
            } label: {
                Label(String(localized: "Sort"), systemImage: "arrow.up.arrow.down")
            }
            .help(String(localized: "Sort History"))

            if let record = viewModel.selectedRecord {
                if record.isOpenInInbox {
                    Button {
                        viewModel.markComplete([record])
                    } label: {
                        Label(String(localized: "Mark Complete"), systemImage: "checkmark.circle")
                    }
                } else if record.inboxState == .completed {
                    Button {
                        viewModel.reopen([record])
                    } label: {
                        Label(String(localized: "Reopen"), systemImage: "arrow.uturn.backward.circle")
                    }
                }

                Button {
                    viewModel.copyToClipboard(record.displayText)
                } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)

                if viewModel.isDirty {
                    Button(String(localized: "Discard")) {
                        viewModel.discardEditing()
                    }
                    Button(String(localized: "Save")) {
                        viewModel.saveEditing()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!viewModel.canSaveDraft)
                }
            }
        }
    }

    @ViewBuilder
    private func filterMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func recordContextMenu(for record: TranscriptionRecord) -> some View {
        let selected = viewModel.selectedRecordIDs.contains(record.id) && viewModel.selectedRecordIDs.count > 1
            ? viewModel.selectedRecords
            : [record]

        Button(String(localized: "Copy")) {
            viewModel.copyToClipboard(selected.map(\.displayText).joined(separator: "\n\n"))
        }

        Menu(String(localized: "Export as…")) {
            Button(String(localized: "Markdown (.md)")) { export(selected, as: .markdown) }
            Button(String(localized: "Plain Text (.txt)")) { export(selected, as: .plainText) }
            Button(String(localized: "JSON (.json)")) { export(selected, as: .json) }
        }

        if selected.contains(where: \.isOpenInInbox) {
            Divider()
            Button(String(localized: "Mark Complete")) { viewModel.markComplete(selected) }
        }
        if selected.contains(where: { $0.inboxState == .completed }) {
            Divider()
            Button(String(localized: "Reopen")) { viewModel.reopen(selected) }
        }

        Divider()
        Button(String(localized: "Delete"), role: .destructive) {
            viewModel.requestDeletion(of: Set(selected.map(\.id)))
        }
    }

    private var deleteConfirmationTitle: String {
        deleteCandidateIDs.count == 1
            ? String(localized: "Delete Entry?")
            : String.localizedStringWithFormat(
                String(localized: "Delete %lld Entries?"),
                Int64(deleteCandidateIDs.count)
            )
    }

    private var deleteConfirmationMessage: String {
        if ServiceContainer.shared.historySyncPreferences.isEnabled {
            return String(localized: "This removes the selected history from every synchronized device. This cannot be undone.")
        }
        return String(localized: "This removes the selected history from this Mac. This cannot be undone.")
    }

    private func deleteRecords(with ids: Set<UUID>) {
        let records = viewModel.records.filter { ids.contains($0.id) }
        viewModel.deleteRecords(records)
        deleteCandidateIDs = []
    }

    private func export(_ records: [TranscriptionRecord], as format: HistoryExportFormat) {
        viewModel.exportRecords(records, format: format)
    }
}

private struct HistoryWindowCloseGuard: NSViewRepresentable {
    @ObservedObject var viewModel: HistoryViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let viewModel: HistoryViewModel
        private weak var window: NSWindow?
        // AppKit invokes window delegates on the main thread, while NSObject's
        // forwarding hooks are imported as nonisolated.
        nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?
        private var isClosingAfterConfirmation = false

        init(viewModel: HistoryViewModel) {
            self.viewModel = viewModel
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            viewModel.installCloseWindowHandler { [weak self] in
                self?.closeAfterConfirmation()
            }
        }

        func detach() {
            if let window, window.delegate === self {
                window.delegate = previousDelegate
            }
            self.window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isClosingAfterConfirmation {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            if viewModel.isDirty {
                viewModel.requestWindowClose()
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) {
                return true
            }
            return (previousDelegate as AnyObject?)?.responds(to: selector) == true
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            if let previousDelegate,
               (previousDelegate as AnyObject).responds(to: selector) {
                return previousDelegate
            }
            return super.forwardingTarget(for: selector)
        }

        private func closeAfterConfirmation() {
            guard let window else { return }
            isClosingAfterConfirmation = true
            window.performClose(nil)
            isClosingAfterConfirmation = false
        }
    }
}
