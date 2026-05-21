import SwiftUI

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

    @State private var isPickerPresented = false
    @State private var searchQuery = ""
    @State private var pendingRestrictedSelection = false

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
                    FlowLayout(spacing: 2) {
                        ForEach(selectedCodes, id: \.self) { code in
                            LanguageChip(
                                code: code,
                                title: localizedAppLanguageName(for: code),
                                removeAction: { removeCode(code) }
                            )
                        }
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

    private func applySelection(for codes: [String]) {
        guard !codes.isEmpty else {
            pendingRestrictedSelection = true
            selection = .auto
            return
        }
        pendingRestrictedSelection = false
        selection = selection.withSelectedCodes(codes, nilBehavior: .auto)
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
    let code: String
    let title: String
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            LanguageCodeBadge(code: code)
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button(action: removeAction) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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
