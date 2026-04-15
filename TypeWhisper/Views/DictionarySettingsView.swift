import SwiftUI
import TypeWhisperPluginSDK

struct DictionarySettingsView: View {
    @ObservedObject private var viewModel = DictionaryViewModel.shared
    @ObservedObject private var termPackRegistryService: TermPackRegistryService
    @ObservedObject private var pluginManager: PluginManager

    init() {
        _termPackRegistryService = ObservedObject(wrappedValue: TermPackRegistryService.shared)
        _pluginManager = ObservedObject(wrappedValue: PluginManager.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.entries.isEmpty && viewModel.filterTab != .termPacks {
                emptyState
            } else {
                // Header with filter and add button
                HStack {
                    Picker("", selection: $viewModel.filterTab) {
                        Text(String(localized: "All")).tag(DictionaryViewModel.FilterTab.all)
                        Text(String(localized: "Terms")).tag(DictionaryViewModel.FilterTab.terms)
                        Text(String(localized: "Corrections")).tag(DictionaryViewModel.FilterTab.corrections)
                        Text(String(localized: "Term Packs")).tag(DictionaryViewModel.FilterTab.termPacks)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)

                    Spacer()

                    if viewModel.filterTab != .termPacks {
                        Button {
                            viewModel.startCreating(type: .correction)
                        } label: {
                            Label(String(localized: "Correction"), systemImage: "plus")
                        }
                        Button {
                            viewModel.startCreating(type: .term)
                        } label: {
                            Label(String(localized: "Term"), systemImage: "plus")
                        }
                    }

                    Menu {
                        Button {
                            viewModel.exportDictionary()
                        } label: {
                            Label(String(localized: "Export..."), systemImage: "square.and.arrow.up")
                        }
                        .disabled(viewModel.entries.isEmpty)

                        Button {
                            viewModel.importDictionary()
                        } label: {
                            Label(String(localized: "Import..."), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

                if viewModel.filterTab != .termPacks, !engineSupportRows.isEmpty {
                    DictionaryEngineSupportSection(rows: engineSupportRows)
                        .padding(.bottom, 8)
                }

                if viewModel.filterTab == .termPacks {
                    termPacksView
                } else if viewModel.filteredEntries.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "No entries for this filter"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.filteredEntries) { entry in
                                DictionaryCardView(entry: entry, viewModel: viewModel)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .sheet(isPresented: $viewModel.isEditing) {
            DictionaryEditorSheet(viewModel: viewModel)
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearError() }
        } message: {
            Text(viewModel.error ?? "")
        }
        .alert(String(localized: "Import Complete"), isPresented: Binding(
            get: { viewModel.importMessage != nil },
            set: { if !$0 { viewModel.clearImportMessage() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearImportMessage() }
        } message: {
            Text(viewModel.importMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No dictionary entries"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Terms help only on engines that support transcription-time biasing. Corrections always run after transcription and apply across engines."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                HStack(spacing: 12) {
                    Button(String(localized: "Add Term")) {
                        viewModel.startCreating(type: .term)
                    }
                    Button(String(localized: "Add Correction")) {
                        viewModel.startCreating(type: .correction)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()
                    .padding(.vertical, 8)
                    .frame(maxWidth: 200)

                Button {
                    viewModel.filterTab = .termPacks
                } label: {
                    Label(String(localized: "Browse Term Packs"), systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)

                Text(String(localized: "Pre-built collections of technical terms for common domains"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.importDictionary()
                } label: {
                    Label(String(localized: "Import Dictionary..."), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    private var termPacksView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Built-in Packs
                ForEach(TermPack.allPacks) { pack in
                    TermPackCardView(pack: pack, viewModel: viewModel)
                }

                // Community Packs
                communityPacksSection
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var communityPacksSection: some View {
        Section {
            switch termPackRegistryService.fetchState {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Text(String(localized: "Loading community packs..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 12)

            case .error(let message):
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text(String(localized: "Failed to load community packs."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        Button(String(localized: "Retry")) {
                            Task { await termPackRegistryService.fetchRegistry(force: true) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)

            case .loaded:
                if termPackRegistryService.communityPacks.isEmpty {
                    HStack {
                        Spacer()
                        Text(String(localized: "No community packs available yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(termPackRegistryService.communityPacks) { pack in
                        TermPackCardView(pack: pack, viewModel: viewModel)
                    }
                }
            }
        } header: {
            Text(String(localized: "Community Packs"))
                .font(.callout)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
        .task {
            await termPackRegistryService.fetchRegistry()
        }
    }

    private var engineSupportRows: [DictionaryEngineSupportRow] {
        pluginManager.transcriptionEngines
            .map {
                DictionaryEngineSupportRow(
                    engineName: $0.providerDisplayName,
                    support: ($0 as? any DictionaryTermsCapabilityProviding)?.dictionaryTermsSupport ?? .unsupported
                )
            }
            .sorted { $0.engineName.localizedCaseInsensitiveCompare($1.engineName) == .orderedAscending }
    }
}

private struct DictionaryEngineSupportRow: Identifiable {
    let engineName: String
    let support: DictionaryTermsSupport

    var id: String { engineName }

    var badgeText: LocalizedStringKey {
        switch support {
        case .supported:
            return "Terms + Corrections"
        case .requiresPluginSetting:
            return "Terms requires plugin setting"
        case .unsupported:
            return "Corrections only"
        }
    }

    var tint: Color {
        switch support {
        case .supported:
            return .accentColor
        case .requiresPluginSetting:
            return .orange
        case .unsupported:
            return .secondary
        }
    }

    var detailText: LocalizedStringKey? {
        switch support {
        case .supported:
            return nil
        case .requiresPluginSetting:
            if engineName == "Parakeet" {
                return "Terms work only when Vocabulary Boosting is enabled in the Parakeet plugin settings."
            }
            return "This engine needs an extra plugin setting before Terms are applied."
        case .unsupported:
            if engineName == "Cohere" {
                return "Cohere currently ignores Terms. Dictionary Corrections still apply after transcription."
            }
            return "This engine currently uses Dictionary Corrections only."
        }
    }
}

private struct DictionaryEngineSupportSection: View {
    let rows: [DictionaryEngineSupportRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Engine Support"))
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(String(localized: "Terms depend on engine support. Corrections always run after transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(row.engineName)
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            Text(row.badgeText)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(row.tint.opacity(0.14))
                                .foregroundStyle(row.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }

                        if let detailText = row.detailText {
                            Text(detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                }
            }
        }
    }
}

// MARK: - Term Pack Card

private struct TermPackCardView: View {
    let pack: TermPack
    @ObservedObject var viewModel: DictionaryViewModel
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isActivated: Bool {
        viewModel.isPackActivated(pack)
    }

    private var showUpdate: Bool {
        isActivated && viewModel.hasUpdate(for: pack)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: pack.icon)
                    .font(.title3)
                    .foregroundStyle(isActivated ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pack.name)
                            .font(.callout)
                            .fontWeight(.medium)

                        if showUpdate {
                            Text(String(localized: "Update Available"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    HStack(spacing: 4) {
                        Text(pack.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if pack.source == .community, let author = pack.author {
                            Text("-")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "by \(author)"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Text(String(localized: "\(pack.entryCount) entries"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if showUpdate {
                    Button(String(localized: "Update")) {
                        viewModel.updatePack(pack)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }

                Toggle("", isOn: Binding(
                    get: { isActivated },
                    set: { _ in viewModel.togglePack(pack) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Enable \(pack.name)"))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Show terms for \(pack.name)"))
                .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 8) {
                    if !pack.terms.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(pack.terms, id: \.self) { term in
                                Text(term)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }

                    if !pack.corrections.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(pack.corrections, id: \.self) { correction in
                                HStack(spacing: 4) {
                                    Text(correction.original)
                                        .strikethrough()
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(correction.replacement)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Dictionary Card

private struct DictionaryCardView: View {
    let entry: DictionaryEntry
    @ObservedObject var viewModel: DictionaryViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.type.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(entry.type == .correction ? Color.orange : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((entry.type == .correction ? Color.orange : Color.accentColor).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            if entry.type == .correction, let replacement = entry.replacement {
                Text(entry.original)
                    .font(.callout)
                    .strikethrough()
                    .foregroundStyle(.secondary)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(replacement)
                    .font(.callout)
                    .fontWeight(.medium)
            } else {
                Text(entry.original)
                    .font(.callout)
                    .fontWeight(.medium)
            }

            if entry.caseSensitive {
                Text("Aa")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { _ in viewModel.toggleEntry(entry) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(entry.original)"))
            .onTapGesture {}
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            viewModel.startEditing(entry)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(String(localized: "Edit")) {
                viewModel.startEditing(entry)
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteEntry(entry)
            }
        }
    }
}

// MARK: - Editor Sheet

private struct DictionaryEditorSheet: View {
    @ObservedObject var viewModel: DictionaryViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case original, replacement
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.isCreatingNew
                     ? (viewModel.editType == .term ? String(localized: "New Term") : String(localized: "New Correction"))
                     : (viewModel.editType == .term ? String(localized: "Edit Term") : String(localized: "Edit Correction")))
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                Text(viewModel.editType == .term
                     ? String(localized: "Terms are sent only to engines that support transcription-time biasing")
                     : String(localized: "Corrections replace text after transcription"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox(viewModel.editType == .term ? String(localized: "Term") : String(localized: "Correction")) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.editType == .term ? String(localized: "Term") : String(localized: "Wrong Text"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(
                                viewModel.editType == .term
                                    ? String(localized: "e.g. Kubernetes")
                                    : String(localized: "e.g. kubernetees"),
                                text: $viewModel.editOriginal
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .original)
                        }

                        if viewModel.editType == .correction {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(localized: "Correct Text"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(String(localized: "e.g. Kubernetes"), text: $viewModel.editReplacement)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .replacement)
                            }
                        }

                        Toggle(String(localized: "Case sensitive"), isOn: $viewModel.editCaseSensitive)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    viewModel.cancelEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Save")) {
                    viewModel.saveEditing()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.editOriginal.isEmpty || (viewModel.editType == .correction && viewModel.editReplacement.isEmpty))
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 400, height: 340)
        .onAppear {
            focusedField = .original
        }
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
