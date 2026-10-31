import Foundation

func preferredAppLanguageCode() -> String {
    if let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage), !language.isEmpty {
        return language
    }

    if let preferred = Bundle.main.preferredLocalizations.first, !preferred.isEmpty {
        return preferred
    }

    return Locale.current.language.languageCode?.identifier ?? "en"
}

/// Returns the text for the app language. German comes from the call site; Japanese,
/// Chinese and Spanish come from the call site when given, otherwise from the string
/// catalog entry whose key is the English text. Text with interpolated values can't be
/// found in the catalog that way, so those call sites pass their translations inline.
func localizedAppText(
    _ english: String,
    de german: String,
    ja japanese: String? = nil,
    zh chinese: String? = nil,
    es spanish: String? = nil
) -> String {
    let language = preferredAppLanguageCode()
    if language.hasPrefix("de") {
        return german
    }

    if language.hasPrefix("ja") {
        if let japanese {
            return japanese
        }

        let localized = Bundle.main.localizedString(forKey: english, value: nil, table: nil)
        if localized != english {
            return localized
        }
    }

    if language.hasPrefix("zh") {
        if let chinese {
            return chinese
        }

        let localized = Bundle.main.localizedString(forKey: english, value: nil, table: nil)
        if localized != english {
            return localized
        }
    }

    if language.hasPrefix("es") {
        if let spanish {
            return spanish
        }

        let localized = Bundle.main.localizedString(forKey: english, value: nil, table: nil)
        if localized != english {
            return localized
        }
    }

    return english
}

func localizedAppLanguageName(for code: String) -> String {
    guard code != "auto" else {
        return localizedAppText("Auto-Detect", de: "Automatisch erkennen")
    }
    guard code != "multi" else {
        return localizedAppText("Multilingual", de: "Mehrsprachig")
    }

    let locale = Locale(identifier: preferredAppLanguageCode())
    return locale.localizedString(forIdentifier: spokenLanguageIdentifier(for: code)) ?? code
}

/// Speech engines such as Apple Speech and Deepgram use zh-HK for Hong Kong Cantonese, which
/// Locale names "Chinese (Hong Kong)". Naming it after the spoken language sets it apart from
/// Chinese (Taiwan), which is Mandarin.
private func spokenLanguageIdentifier(for code: String) -> String {
    let language = Locale.Language(identifier: code)
    guard language.languageCode == .chinese, language.region == .hongKong else {
        return code
    }
    return "yue-HK"
}

struct LocalizedAppLanguageOption: Equatable {
    let code: String
    let name: String
}

let defaultSpokenLanguageCodes: [String] = [
    "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
    "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
    "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
    "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
    "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
    "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
    "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
    "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
    "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
    "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
    "zh",
]

func localizedAppLanguageOptions(for codes: [String]) -> [LocalizedAppLanguageOption] {
    codes.map { code in
        LocalizedAppLanguageOption(code: code, name: localizedAppLanguageName(for: code))
    }
}

func localizedAppLanguageSearchTerms(for code: String, preferredDisplayName: String? = nil) -> [String] {
    var terms: [String] = []

    if let preferredDisplayName {
        appendLanguageSearchTerm(preferredDisplayName, to: &terms)
    }

    appendLanguageSearchTerm(code, to: &terms)
    appendLanguageSearchTerm(localizedAppLanguageName(for: code), to: &terms)
    if code == "multi" {
        appendLanguageSearchTerm("Multilingual", to: &terms)
        appendLanguageSearchTerm("Mehrsprachig", to: &terms)
    }

    let locales = [
        Locale.current,
        Locale(identifier: "en"),
        Locale(identifier: code)
    ]

    for locale in locales {
        appendLanguageSearchTerm(locale.localizedString(forIdentifier: code), to: &terms)
    }

    return terms
}

private func appendLanguageSearchTerm(_ value: String?, to terms: inout [String]) {
    guard let value else { return }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }

    terms.append(trimmed)
}

func localizedAppLanguageBadgeText(for code: String) -> String {
    let components = NSLocale.components(fromLocaleIdentifier: code)
    let languageKey = NSLocale.Key.languageCode.rawValue
    guard let languageCode = components[languageKey], !languageCode.isEmpty else {
        return code.uppercased()
    }

    if code.contains("-") {
        return code.uppercased()
    }

    return languageCode.uppercased()
}

struct LocalizedAppLanguageBadgeDescriptor: Equatable {
    let text: String
    let accessibilityLabel: String
}

func localizedAppLanguageBadgeDescriptor(for code: String) -> LocalizedAppLanguageBadgeDescriptor {
    LocalizedAppLanguageBadgeDescriptor(
        text: localizedAppLanguageBadgeText(for: code),
        accessibilityLabel: localizedAppLanguageName(for: code)
    )
}

func localizedAppLanguageNames(for codes: [String]) -> [String] {
    codes.map(localizedAppLanguageName(for:))
}

func localizedAppLanguageList(_ codes: [String]) -> String {
    let names = localizedAppLanguageNames(for: codes)
    guard let first = names.first else { return "" }
    if names.count == 1 { return first }
    if names.count == 2 {
        return "\(first)\(localizedAppOrSeparator())\(names[1])"
    }
    let allButLast = names.dropLast().joined(separator: ", ")
    return "\(allButLast),\(localizedAppText(" and ", de: " und "))\(names[names.count - 1])"
}

func localizedAppOrSeparator() -> String {
    localizedAppText(" or ", de: " oder ")
}

func featuredAppLanguageRank(for code: String) -> Int? {
    let components = NSLocale.components(fromLocaleIdentifier: code)
    let languageKey = NSLocale.Key.languageCode.rawValue
    guard let languageCode = components[languageKey]?.lowercased() else {
        return nil
    }

    let featuredLanguageOrder = [
        "de",
        "en",
        "fr",
        "es",
        "zh",
        "hi",
        "ar",
        "pt",
        "ja"
    ]

    return featuredLanguageOrder.firstIndex(of: languageCode)
}
