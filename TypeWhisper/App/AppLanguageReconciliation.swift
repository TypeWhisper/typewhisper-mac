import Foundation

/// Aligns a saved in-app selection with the languages macOS uses for the app before any
/// localization is read. Runs from `main.swift` after `TestHostIsolation` and before the
/// `OverrideBundle` swap.
///
/// A launch argument (`-AppleLanguages`) applies only to that launch. Otherwise the per-app
/// `AppleLanguages` wins, and when macOS removed it ("System Language" in System Settings) the
/// inherited global list is used, so the saved selection follows the language SwiftUI shows.
/// Requested languages the app does not support resolve to the development language, as SwiftUI does.
func reconcileAppLanguage(defaults: UserDefaults = .standard, preferencesDomain: String) {
    let appPreferences = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
    guard let savedLanguage = appPreferences[UserDefaultsKeys.preferredAppLanguage] as? String,
          !savedLanguage.isEmpty else { return }

    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let isLaunchOverride = arguments["AppleLanguages"] != nil
    guard let languages = isLaunchOverride
            ? arguments["AppleLanguages"] as? [String]
            : defaults.stringArray(forKey: "AppleLanguages"),
          !languages.isEmpty,
          let language = Bundle.preferredLocalizations(
            from: Bundle.main.localizations.filter { $0 != "Base" },
            forPreferences: languages
          ).first else { return }

    if isLaunchOverride {
        // Merge into the argument domain so this launch never changes the saved choice.
        arguments[UserDefaultsKeys.preferredAppLanguage] = language
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    } else if savedLanguage != language {
        defaults.set(language, forKey: UserDefaultsKeys.preferredAppLanguage)
    }
}
