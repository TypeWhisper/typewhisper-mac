import SwiftUI
import TypeWhisperPluginSDK

enum LanguageSelectionHintBehavior: Equatable {
    case unknown
    case acceptsHints
    case firstSelectedFallback

    init(engine: TranscriptionEnginePlugin?) {
        guard let engine else {
            self = .unknown
            return
        }
        self = engine.acceptsLanguageHints ? .acceptsHints : .firstSelectedFallback
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
    var hintBehavior: LanguageSelectionHintBehavior = .unknown

    @State private var isPickerPresented = false
    @State private var searchQuery = ""
    @State private var pendingRestrictedSelection = false
    @State private var dropTargetedCode: String?

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

    private var restrictedHelpText: String? {
        guard selectedCodes.count > 1 else { return nil }

        switch hintBehavior {
        case .acceptsHints:
            return "This engine uses the ordered list as language hints."
        case .firstSelectedFallback:
            return "This engine does not support multiple language hints. It will use #1 as the spoken language."
        case .unknown:
            return "Engines that support language hints use this ordered list. Other engines use #1 as the spoken language."
        }
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
                    selectedLanguageChips

                    if let restrictedHelpText {
                        Text(restrictedHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private var selectedLanguageChips: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(selectedCodes.enumerated()), id: \.element) { index, code in
                LanguageChip(
                    priority: index + 1,
                    code: code,
                    title: localizedAppLanguageName(for: code),
                    isDropTargeted: dropTargetedCode == code,
                    canMoveEarlier: index > 0,
                    canMoveLater: index < selectedCodes.count - 1,
                    moveEarlierAction: { moveCode(code, by: -1) },
                    moveLaterAction: { moveCode(code, by: 1) },
                    removeAction: { removeCode(code) },
                    dropAction: { droppedCode in moveDroppedCode(droppedCode, onto: code) },
                    dropTargetAction: { isTargeted in
                        dropTargetedCode = isTargeted ? code : (dropTargetedCode == code ? nil : dropTargetedCode)
                    }
                )
            }
        }
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

    private func moveCode(_ code: String, by offset: Int) {
        selection = selection.withSelectedCodeMoved(code, by: offset, nilBehavior: nilBehavior)
    }

    private func moveDroppedCode(_ code: String, onto targetCode: String) -> Bool {
        let moved = selection.withSelectedCodeMoved(code, droppedOn: targetCode, nilBehavior: nilBehavior)
        guard moved != selection else { return false }
        selection = moved
        return true
    }

    private func applySelection(for codes: [String]) {
        guard !codes.isEmpty else {
            pendingRestrictedSelection = true
            selection = nilBehavior == .inheritGlobal ? .inheritGlobal : .auto
            return
        }
        pendingRestrictedSelection = false
        selection = selection.withSelectedCodes(codes, nilBehavior: nilBehavior)
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
                LanguageCodeBadge(code: language.code)
                Text(language.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
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
    let priority: Int
    let code: String
    let title: String
    let isDropTargeted: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let moveEarlierAction: () -> Void
    let moveLaterAction: () -> Void
    let removeAction: () -> Void
    let dropAction: (String) -> Bool
    let dropTargetAction: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(priority)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                }
            LanguageCodeBadge(code: code)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button(action: moveEarlierAction) {
                Image(systemName: "chevron.left")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveEarlier)
            .help("Move earlier")
            .accessibilityLabel("Move \(title) earlier")

            Button(action: moveLaterAction) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveLater)
            .help("Move later")
            .accessibilityLabel("Move \(title) later")

            Button(action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(title)")
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
                .strokeBorder(isDropTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .draggable(code)
        .dropDestination(for: String.self) { droppedCodes, _ in
            guard let droppedCode = droppedCodes.first else { return false }
            return dropAction(droppedCode)
        } isTargeted: { targeted in
            dropTargetAction(targeted)
        }
    }
}

struct LanguageCodeBadge: View {
    let code: String

    private var descriptor: LocalizedAppLanguageBadgeDescriptor {
        localizedAppLanguageBadgeDescriptor(for: code)
    }

    var body: some View {
        Text(descriptor.text)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(minWidth: 34, maxWidth: 72, minHeight: 18)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(descriptor.accessibilityLabel)
    }
}
