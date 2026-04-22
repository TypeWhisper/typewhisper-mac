import AppKit
import Combine
import Foundation

enum LegacyWorkflowSourceKind: String, CaseIterable, Sendable {
    case rule
    case prompt

    var title: String {
        switch self {
        case .rule:
            localizedAppText("Legacy Rule", de: "Legacy-Regel")
        case .prompt:
            localizedAppText("Legacy Prompt", de: "Legacy-Prompt")
        }
    }
}

struct LegacyWorkflowItem: Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: LegacyWorkflowSourceKind
    let sourceObjectId: UUID
    let name: String
    let summary: String
    let detail: String
    let isEnabled: Bool
    let isImported: Bool
}

@MainActor
final class LegacyWorkflowService: ObservableObject {
    static let importedDefaultsKey = "legacyWorkflowImportedIds"

    @Published private(set) var items: [LegacyWorkflowItem] = []

    private let profileService: ProfileService
    private let promptActionService: PromptActionService
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var importedIds: Set<String>

    init(
        profileService: ProfileService,
        promptActionService: PromptActionService,
        defaults: UserDefaults = .standard
    ) {
        self.profileService = profileService
        self.promptActionService = promptActionService
        self.defaults = defaults
        self.importedIds = Set(defaults.stringArray(forKey: Self.importedDefaultsKey) ?? [])

        rebuildItems()
        setupBindings()
    }

    var ruleItems: [LegacyWorkflowItem] {
        items.filter { $0.sourceKind == .rule }
    }

    var promptItems: [LegacyWorkflowItem] {
        items.filter { $0.sourceKind == .prompt }
    }

    func deleteItem(_ item: LegacyWorkflowItem) {
        switch item.sourceKind {
        case .rule:
            guard let profile = profileService.profiles.first(where: { $0.id == item.sourceObjectId }) else { return }
            profileService.deleteProfile(profile)
        case .prompt:
            let promptId = item.sourceObjectId.uuidString
            let linkedProfiles = profileService.profiles.filter { $0.promptActionId == promptId }
            for profile in linkedProfiles {
                profile.promptActionId = nil
                profileService.updateProfile(profile)
            }

            guard let promptAction = promptActionService.promptActions.first(where: { $0.id == item.sourceObjectId }) else { return }
            promptActionService.deleteAction(promptAction)
        }

        rebuildItems()
    }

    func markImported(_ item: LegacyWorkflowItem) {
        importedIds.insert(item.id)
        defaults.set(Array(importedIds).sorted(), forKey: Self.importedDefaultsKey)
        rebuildItems()
    }

    private func setupBindings() {
        profileService.$profiles
            .sink { [weak self] _ in
                self?.rebuildItems()
            }
            .store(in: &cancellables)

        promptActionService.$promptActions
            .sink { [weak self] _ in
                self?.rebuildItems()
            }
            .store(in: &cancellables)
    }

    private func rebuildItems() {
        let promptActionsById = Dictionary(
            uniqueKeysWithValues: promptActionService.promptActions.map { ($0.id.uuidString, $0) }
        )

        let legacyRules = profileService.profiles.map { profile in
            buildLegacyRuleItem(profile: profile, promptActionsById: promptActionsById)
        }

        let legacyPrompts = promptActionService.promptActions.map { prompt in
            buildLegacyPromptItem(promptAction: prompt)
        }

        items = (legacyRules + legacyPrompts).sorted { lhs, rhs in
            if lhs.sourceKind != rhs.sourceKind {
                return lhs.sourceKind.rawValue < rhs.sourceKind.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func buildLegacyRuleItem(
        profile: Profile,
        promptActionsById: [String: PromptAction]
    ) -> LegacyWorkflowItem {
        let promptAction = profile.promptActionId.flatMap { promptActionsById[$0] }
        let contextSummary = legacyContextSummary(for: profile)
        let behaviorSummary = legacyBehaviorSummary(for: profile, promptAction: promptAction)

        return LegacyWorkflowItem(
            id: "rule-\(profile.id.uuidString)",
            sourceKind: .rule,
            sourceObjectId: profile.id,
            name: profile.name,
            summary: contextSummary,
            detail: behaviorSummary,
            isEnabled: profile.isEnabled,
            isImported: importedIds.contains("rule-\(profile.id.uuidString)")
        )
    }

    private func buildLegacyPromptItem(promptAction: PromptAction) -> LegacyWorkflowItem {
        let linkedRuleCount = profileService.profiles.filter { $0.promptActionId == promptAction.id.uuidString }.count
        let detail: String
        if linkedRuleCount == 0 {
            detail = localizedAppText(
                "Not linked to any legacy rules.",
                de: "Mit keiner Legacy-Regel verknuepft."
            )
        } else if linkedRuleCount == 1 {
            detail = localizedAppText(
                "Used by 1 legacy rule.",
                de: "Wird von 1 Legacy-Regel verwendet."
            )
        } else {
            detail = localizedAppText(
                "Used by \(linkedRuleCount) legacy rules.",
                de: "Wird von \(linkedRuleCount) Legacy-Regeln verwendet."
            )
        }

        return LegacyWorkflowItem(
            id: "prompt-\(promptAction.id.uuidString)",
            sourceKind: .prompt,
            sourceObjectId: promptAction.id,
            name: promptAction.name,
            summary: localizedAppText(
                "Legacy prompt action",
                de: "Legacy-Prompt-Aktion"
            ),
            detail: detail,
            isEnabled: promptAction.isEnabled,
            isImported: importedIds.contains("prompt-\(promptAction.id.uuidString)")
        )
    }

    private func legacyContextSummary(for profile: Profile) -> String {
        if let hotkey = profile.hotkey {
            return localizedAppText(
                "Manual trigger via \(HotkeyService.displayName(for: hotkey))",
                de: "Manueller Trigger per \(HotkeyService.displayName(for: hotkey))"
            )
        }

        let appNames = profile.bundleIdentifiers.prefix(2).map(legacyAppName(for:))
        let domains = profile.urlPatterns.prefix(2)

        if let appName = appNames.first, let domain = domains.first {
            return localizedAppText(
                "App \(appName) and website \(domain)",
                de: "App \(appName) und Website \(domain)"
            )
        }
        if let domain = domains.first {
            return localizedAppText(
                "Website \(domain)",
                de: "Website \(domain)"
            )
        }
        if let appName = appNames.first {
            return localizedAppText(
                "App \(appName)",
                de: "App \(appName)"
            )
        }

        return localizedAppText(
            "No explicit trigger",
            de: "Kein expliziter Trigger"
        )
    }

    private func legacyBehaviorSummary(for profile: Profile, promptAction: PromptAction?) -> String {
        var parts: [String] = []

        if let promptAction {
            parts.append(
                localizedAppText(
                    "Prompt: \(promptAction.name)",
                    de: "Prompt: \(promptAction.name)"
                )
            )
        } else if profile.inlineCommandsEnabled {
            parts.append(localizedAppText("Inline commands", de: "Inline-Commands"))
        }

        if profile.translationEnabled == true,
           let targetLanguage = profile.translationTargetLanguage,
           !targetLanguage.isEmpty {
            parts.append(
                localizedAppText(
                    "Translation to \(localizedAppLanguageName(for: targetLanguage))",
                    de: "Uebersetzung nach \(localizedAppLanguageName(for: targetLanguage))"
                )
            )
        } else if let outputFormat = profile.outputFormat, !outputFormat.isEmpty {
            parts.append(
                localizedAppText(
                    "Output: \(outputFormat)",
                    de: "Ausgabe: \(outputFormat)"
                )
            )
        }

        if let engineOverride = profile.engineOverride, !engineOverride.isEmpty {
            parts.append(
                localizedAppText(
                    "Engine: \(engineOverride)",
                    de: "Engine: \(engineOverride)"
                )
            )
        }

        if parts.isEmpty {
            return localizedAppText(
                "Legacy rule behavior",
                de: "Legacy-Regelverhalten"
            )
        }

        return parts.joined(separator: " • ")
    }

    private func legacyAppName(for bundleIdentifier: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let bundle = Bundle(url: appURL),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }

        let fallback = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        return fallback.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
