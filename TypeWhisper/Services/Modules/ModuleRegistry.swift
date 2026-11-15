import Foundation
import os
import TypeWhisperModuleKit
import TypeWhisperModules

/// Loads the modules the app is built with and keeps their contributions.
///
/// Builds from this repository link the stub package, which has no modules.
@MainActor
final class ModuleRegistry {
    /// True when the linked `TypeWhisperModules` package is the stub.
    let isStub: Bool
    private(set) var modules: [any HostModule] = []
    private(set) var contributions = ModuleContributions()

    init(
        entry: any ModuleEntryPoint.Type = ModuleEntry.self,
        host: any ModuleHost,
        kitVersion: ModuleKitVersion = .current
    ) {
        isStub = entry.isStub
        let required = entry.requiredModuleKitVersion
        guard kitVersion.supports(required) else {
            Logger(subsystem: AppConstants.loggerSubsystem, category: "Modules").error(
                "Modules skipped: they require interface \(required.description, privacy: .public), the app has \(kitVersion.description, privacy: .public)"
            )
            return
        }
        modules = entry.makeModules()
        for module in modules {
            contributions.append(module.contributions(for: host))
        }
    }
}

/// The app's side of `ModuleHost`.
@MainActor
final class AppModuleHost: ModuleHost {
    // Each capability is provided once the app implements it.
    var historyReading: (any HistoryReading)? { nil }
    var historySearching: (any HistorySearching)? { nil }
    var languageModelAnswering: (any LanguageModelAnswering)? { nil }
    // Qualified: the app has its own ManagedPolicyReading for the raw managed preferences.
    var managedPolicyReading: (any TypeWhisperModuleKit.ManagedPolicyReading)? { nil }
    var premiumAccessReading: (any PremiumAccessReading)? { nil }
    var userDataLifecycle: (any UserDataLifecycle)? { nil }
}
