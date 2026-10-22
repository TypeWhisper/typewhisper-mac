import SwiftUI

struct TranslationShortcutRow: View {
    var body: some View { EmptyView() }
}

struct TranslationLanguagesSection: View {
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            GroupedFormSection(title: "Translation languages") {
                GroupedFormToggle(title: "Translate", isOn: $settings.translationEnabled, separated: false)
                if settings.translationEnabled {
                    GroupedFormRow(separated: true) {
                        Text("Translation languages", tableName: "DictumShell")
                        Spacer()
                        Picker("Translation languages", selection: $settings.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { language in
                                Text(language.name).tag(language.code)
                            }
                        }.labelsHidden().fixedSize()
                    }
                }
            }
        }
        #endif
    }
}
