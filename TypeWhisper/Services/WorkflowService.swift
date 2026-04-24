import Foundation
import SwiftData
import Combine
import os.log

private let workflowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "WorkflowService"
)

enum WorkflowMatchKind: String, Sendable {
    case website
    case app
    case globalFallback
    case manualOverride

    var label: String {
        switch self {
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
    @Published private(set) var workflows: [Workflow] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
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

    func matchWorkflow(bundleIdentifier: String?, url: String? = nil) -> WorkflowMatchResult? {
        let bundleId = bundleIdentifier ?? ""
        let domain = extractDomain(from: url)
        let enabled = workflows.filter(\.isEnabled)

        if let domain {
            let matches = enabled.filter { workflow in
                guard let trigger = workflow.trigger, trigger.kind == .website else { return false }
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
                guard let trigger = workflow.trigger, trigger.kind == .app else { return false }
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
