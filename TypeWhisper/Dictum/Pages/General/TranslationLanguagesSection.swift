import SwiftUI

struct TranslationLanguagesSection: View {
    @ObservedObject private var languages = TranslationLanguageStore.shared
    @ObservedObject private var engine = SettingsViewModel.shared
    @State private var addingLanguage = false
    @State private var query = ""
    private let rowHeight: CGFloat = 38

    private var spokenSelection: Binding<String> {
        Binding(get: { languages.settings.spokenLanguage }, set: { languages.setSpokenLanguage($0) })
    }

    private var spokenOptions: [String] {
        let codes = engine.activeTranscriptionEngine?.supportedLanguages ?? []
        return TranslationLanguageCatalog.spokenOptions(
            engineCodes: codes.isEmpty ? defaultSpokenLanguageCodes : codes,
            selected: languages.settings.spokenLanguage
        )
    }

    private var spokenName: String {
        languages.settings.isAutomatic
            ? String(localized: "Detect automatically", table: "DictumTranslation")
            : TranslationLanguageNames.name(for: languages.settings.spokenLanguage, style: .interface)
    }

    var body: some View {
        let targets = languages.settings.offeredTargets
        GroupedFormSection(
            title: "Translation languages",
            footer: "The first language is the default. Drag to reorder; the voice bar uses this order.",
            tableName: "DictumTranslation"
        ) {
            GroupedFormRow {
                Text("Spoken language", tableName: "DictumTranslation")
                Spacer()
                DictumPopup(title: "Spoken language", selection: spokenSelection, tableName: "DictumTranslation",
                            value: Text(verbatim: spokenName)) {
                    Text("Detect automatically", tableName: "DictumTranslation").tag(TranslationLanguageSettings.automatic)
                    Divider()
                    ForEach(spokenOptions, id: \.self) { code in
                        Text(verbatim: TranslationLanguageNames.name(for: code, style: .interface)).tag(code)
                    }
                }
            }
            GroupedFormRow(separated: true) {
                Text("Translate to", tableName: "DictumTranslation").foregroundStyle(DictumTheme.textSecondary)
                Spacer()
            }
            List {
                ForEach(Array(targets.enumerated()), id: \.element) { index, code in
                    targetRow(code, isDefault: index == 0, canRemove: targets.count > 1)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .frame(height: rowHeight)
                }
                .onMove { languages.moveTargets(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: rowHeight * CGFloat(targets.count))
            GroupedFormRow(separated: true) {
                Button { addingLanguage = true } label: {
                    Label { Text("Add Language", tableName: "DictumTranslation") } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.plain).foregroundStyle(DictumTheme.accent)
                .popover(isPresented: $addingLanguage, arrowEdge: .bottom) { addLanguagePicker }
                Spacer()
            }
        }
    }

    private func targetRow(_ code: String, isDefault: Bool, canRemove: Bool) -> some View {
        HoverRow { hovering in
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(DictumTheme.textTertiary).accessibilityHidden(true)
                Text(verbatim: TranslationLanguageNames.name(for: code))
                Spacer()
                if isDefault { Badge(text: "Default", tint: DictumTheme.accent, tableName: "DictumTranslation") }
                if canRemove {
                    Button { languages.removeTarget(code) } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                        .buttonStyle(.borderless).opacity(hovering ? 1 : 0)
                        .accessibilityLabel(Text("Remove", tableName: "DictumShell"))
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var addLanguagePicker: some View {
        let settings = languages.settings
        let excluded = settings.targets + (settings.isAutomatic ? [] : [settings.spokenLanguage])
        let candidates = TranslationLanguageCatalog.targetCandidates(excluding: excluded).filter { code in
            query.isEmpty || TranslationLanguageNames.name(for: code, style: .interface).localizedCaseInsensitiveContains(query)
                || TranslationLanguageNames.name(for: code).localizedCaseInsensitiveContains(query)
        }
        return VStack(spacing: 8) {
            TextField(text: $query) { Text("Search", tableName: "DictumTranslation") }.textFieldStyle(.roundedBorder)
            List(candidates, id: \.self) { code in
                Button {
                    languages.addTarget(code)
                    addingLanguage = false
                    query = ""
                } label: {
                    Text(verbatim: TranslationLanguageNames.name(for: code, style: .interface)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
        .padding(12).frame(width: 260, height: 320)
    }
}

/// 悬停时才显示行内的移除按钮。
private struct HoverRow<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
