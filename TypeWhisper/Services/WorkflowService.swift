import Foundation
import SwiftData
import Combine
import os.log

private let workflowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "WorkflowService"
)

enum WorkflowMatchKind: String, Sendable {
    case appAndWebsite
    case website
    case app
    case globalFallback
    case manualOverride

    var label: String {
        switch self {
        case .appAndWebsite:
            localizedAppText("App + Website", de: "App + Website")
        case .website:
            localizedAppText("Website", de: "Website")
        case .app:
            localizedAppText("App", de: "App")
        case .globalFallback:
            localizedAppText("Always", de: "Immer")
        case .manualOverride:
            localizedAppText("Manually triggered", de: "Manuell ausgeloest")
        }
    }
}

struct WorkflowMatchResult {
    let workflow: Workflow
    let kind: WorkflowMatchKind
    let matchedDomain: String?
    let competingWorkflowCount: Int
    let wonBySortOrder: Bool
}

@MainActor
final class WorkflowService: ObservableObject {
    static let defaultShortTranscriptionMinimumWords = 0
    static let shortTranscriptionMinimumWordsRange = 0...10

    @Published private(set) var workflows: [Workflow] = []
    @Published var defaultProviderId: String {
        didSet {
            userDefaults.set(defaultProviderId, forKey: UserDefaultsKeys.workflowDefaultLLMProviderId)
            if oldValue != defaultProviderId {
                defaultCloudModel = ""
            }
        }
    }
    @Published var defaultCloudModel: String {
        didSet {
            userDefaults.set(defaultCloudModel, forKey: UserDefaultsKeys.workflowDefaultLLMCloudModel)
        }
    }
    @Published var shortTranscriptionMinimumWords: Int {
        didSet {
            let clamped = Self.clampedShortTranscriptionMinimumWords(shortTranscriptionMinimumWords)
            guard clamped == shortTranscriptionMinimumWords else {
                shortTranscriptionMinimumWords = clamped
                return
            }
            userDefaults.set(clamped, forKey: UserDefaultsKeys.workflowShortTranscriptionMinimumWords)
        }
    }

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let userDefaults: UserDefaults

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.defaultProviderId = userDefaults.string(forKey: UserDefaultsKeys.workflowDefaultLLMProviderId)
            ?? userDefaults.string(forKey: "llmProviderType")
            ?? PromptProcessingService.appleIntelligenceId
        self.defaultCloudModel = userDefaults.string(forKey: UserDefaultsKeys.workflowDefaultLLMCloudModel)
            ?? userDefaults.string(forKey: "llmCloudModel")
            ?? ""
        self.shortTranscriptionMinimumWords = Self.clampedShortTranscriptionMinimumWords(
            userDefaults.object(forKey: UserDefaultsKeys.workflowShortTranscriptionMinimumWords) as? Int
                ?? Self.defaultShortTranscriptionMinimumWords
        )

        let schema = Schema([Workflow.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("workflows.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("workflows.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }

            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create workflows ModelContainer after reset: \(error)")
            }
        }

        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = true

        fetchWorkflows()
    }

    static func clampedShortTranscriptionMinimumWords(_ value: Int) -> Int {
        min(max(value, shortTranscriptionMinimumWordsRange.lowerBound), shortTranscriptionMinimumWordsRange.upperBound)
    }

    func shouldSkipAIProcessingForShortDictation(text: String) -> Bool {
        guard shortTranscriptionMinimumWords > 0 else { return false }

        let wordCount = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .count
        return wordCount > 0 && wordCount < shortTranscriptionMinimumWords
    }

    @discardableResult
    func addWorkflow(
        name: String,
        template: WorkflowTemplate,
        trigger: WorkflowTrigger,
        behavior: WorkflowBehavior = WorkflowBehavior(),
        output: WorkflowOutput = WorkflowOutput(),
        isEnabled: Bool = true,
        sortOrder: Int? = nil
    ) -> Workflow? {
        let workflow = Workflow(
            name: name,
            isEnabled: isEnabled,
            sortOrder: sortOrder ?? nextSortOrder(),
            template: template,
            trigger: trigger,
            behavior: behavior,
            output: output
        )

        modelContext.insert(workflow)
        save()
        fetchWorkflows()
        return workflow
    }

    func nextSortOrder() -> Int {
        (workflows.map(\.sortOrder).max() ?? -1) + 1
    }

    var availableRuleNames: [String] {
        var names: [String] = []
        for workflow in workflows where !names.contains(workflow.name) {
            names.append(workflow.name)
        }
        return names
    }

    func updateWorkflow(_ workflow: Workflow) {
        workflow.updatedAt = Date()
        save()
        fetchWorkflows()
    }

    func deleteWorkflow(_ workflow: Workflow) {
        modelContext.delete(workflow)
        save()
        fetchWorkflows()
    }

    func toggleWorkflow(_ workflow: Workflow) {
        workflow.isEnabled.toggle()
        workflow.updatedAt = Date()
        save()
        fetchWorkflows()
    }

    func reorderWorkflows(_ orderedWorkflows: [Workflow]) {
        for (index, workflow) in orderedWorkflows.enumerated() {
            workflow.sortOrder = index
            workflow.updatedAt = Date()
        }

        save()
        fetchWorkflows()
    }

    @discardableResult
    func moveWorkflow(draggedWorkflowId: UUID, droppedOn targetWorkflowId: UUID) -> Bool {
        guard draggedWorkflowId != targetWorkflowId,
              let fromIndex = workflows.firstIndex(where: { $0.id == draggedWorkflowId }),
              let toIndex = workflows.firstIndex(where: { $0.id == targetWorkflowId }) else {
            return false
        }

        var reordered = workflows
        let movedWorkflow = reordered.remove(at: fromIndex)
        // The original target index inserts before the target when moving up and
        // after the shifted target when moving down.
        let insertionIndex = toIndex
        guard insertionIndex >= reordered.startIndex, insertionIndex <= reordered.endIndex else {
            return false
        }

        reordered.insert(movedWorkflow, at: insertionIndex)
        reorderWorkflows(reordered)
        return true
    }

    func workflow(id: UUID) -> Workflow? {
        workflows.first(where: { $0.id == id })
    }

    func forcedWorkflowMatch(for workflow: Workflow) -> WorkflowMatchResult {
        WorkflowMatchResult(
            workflow: workflow,
            kind: .manualOverride,
            matchedDomain: nil,
            competingWorkflowCount: 0,
            wonBySortOrder: false
        )
    }

    func llmProviderId(for workflow: Workflow) -> String? {
        let providerId = workflow.behavior.providerId ?? defaultProviderId
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func llmCloudModel(for workflow: Workflow) -> String? {
        let modelId: String?
        if workflow.behavior.providerId == nil {
            modelId = defaultCloudModel
        } else {
            modelId = workflow.behavior.cloudModel
        }

        let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func matchWorkflow(bundleIdentifier: String?, url: String? = nil) -> WorkflowMatchResult? {
        let bundleId = bundleIdentifier ?? ""
        let domain = extractDomain(from: url)
        let enabled = workflows.filter(\.isEnabled)

        if !bundleId.isEmpty, let domain {
            let matches = enabled.filter { workflow in
                guard let trigger = workflow.trigger,
                      !trigger.appBundleIdentifiers.isEmpty,
                      !trigger.websitePatterns.isEmpty,
                      trigger.appBundleIdentifiers.contains(bundleId) else {
                    return false
                }
                return trigger.websitePatterns.contains { pattern in
                    !pattern.isEmpty && domainMatches(domain, pattern: pattern)
                }
            }
            if let result = bestMatch(from: matches, kind: .appAndWebsite, matchedDomain: domain) {
                return result
            }
        }

        if let domain {
            let matches = enabled.filter { workflow in
                guard let trigger = workflow.trigger,
                      trigger.appBundleIdentifiers.isEmpty,
                      !trigger.websitePatterns.isEmpty else {
                    return false
                }
                return trigger.websitePatterns.contains { pattern in
                    !pattern.isEmpty && domainMatches(domain, pattern: pattern)
                }
            }
            if let result = bestMatch(from: matches, kind: .website, matchedDomain: domain) {
                return result
            }
        }

        if !bundleId.isEmpty {
            let matches = enabled.filter { workflow in
                guard let trigger = workflow.trigger,
                      trigger.websitePatterns.isEmpty else {
                    return false
                }
                return trigger.appBundleIdentifiers.contains(bundleId)
            }
            if let result = bestMatch(from: matches, kind: .app, matchedDomain: nil) {
                return result
            }
        }

        let globalMatches = enabled.filter { workflow in
            workflow.trigger?.kind == .global
        }
        if let result = bestMatch(from: globalMatches, kind: .globalFallback, matchedDomain: nil) {
            return result
        }

        return nil
    }

    private func fetchWorkflows() {
        let descriptor = FetchDescriptor<Workflow>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward), SortDescriptor(\.name)]
        )

        do {
            workflows = try modelContext.fetch(descriptor)
        } catch {
            workflows = []
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            workflowLogger.error("Save failed: \(error.localizedDescription)")
        }
    }

    private func extractDomain(from urlString: String?) -> String? {
        guard let urlString,
              !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host() else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func domainMatches(_ domain: String, pattern: String) -> Bool {
        let normalizedDomain = domain.lowercased()
        let normalizedPattern = pattern.lowercased()
        return normalizedDomain == normalizedPattern || normalizedDomain.hasSuffix("." + normalizedPattern)
    }

    private func bestMatch(
        from matches: [Workflow],
        kind: WorkflowMatchKind,
        matchedDomain: String?
    ) -> WorkflowMatchResult? {
        let sorted = matches.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        guard let best = sorted.first else { return nil }
        let secondSortOrder = sorted.dropFirst().first?.sortOrder

        return WorkflowMatchResult(
            workflow: best,
            kind: kind,
            matchedDomain: matchedDomain,
            competingWorkflowCount: max(sorted.count - 1, 0),
            wonBySortOrder: secondSortOrder.map { best.sortOrder < $0 } ?? false
        )
    }
}
