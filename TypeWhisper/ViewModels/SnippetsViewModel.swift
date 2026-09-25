import Foundation
import Combine

@MainActor
class SnippetsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: SnippetsViewModel?
    static var shared: SnippetsViewModel {
        guard let instance = _shared else {
            fatalError("SnippetsViewModel not initialized")
        }
        return instance
    }

    @Published var snippets: [Snippet] = []
    @Published var error: String?

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var editTrigger = ""
    @Published var editReplacement = ""
    @Published var editCaseSensitive = false
    @Published var editScope: SnippetScope = .dictation

    private let snippetService: SnippetService
    private var cancellables = Set<AnyCancellable>()
    private var selectedSnippet: Snippet?

    var enabledCount: Int { snippetService.enabledSnippetsCount }
    var totalCount: Int { snippets.count }

    init(snippetService: SnippetService) {
        self.snippetService = snippetService
        self.snippets = snippetService.snippets
        setupBindings()
    }

    private func setupBindings() {
        snippetService.$snippets
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snippets in
                self?.snippets = snippets
            }
            .store(in: &cancellables)
    }

    // MARK: - Editor Actions

    func startCreating() {
        selectedSnippet = nil
        isCreatingNew = true
        isEditing = true
        editTrigger = ""
        editReplacement = ""
        editCaseSensitive = false
        editScope = .dictation
    }

    func startEditing(_ snippet: Snippet) {
        selectedSnippet = snippet
        isCreatingNew = false
        isEditing = true
        editTrigger = snippet.trigger
        editReplacement = snippet.replacement
        editCaseSensitive = snippet.caseSensitive
        editScope = snippet.scope ?? .dictation
    }

    func cancelEditing() {
        isEditing = false
        isCreatingNew = false
        selectedSnippet = nil
        editTrigger = ""
        editReplacement = ""
        editCaseSensitive = false
    }

    func saveEditing() {
        guard !editTrigger.isEmpty, !editReplacement.isEmpty else {
            error = String(localized: "Trigger and replacement cannot be empty")
            return
        }

        if let validationError = snippetService.transformValidationError(
            trigger: editTrigger, replacement: editReplacement, scope: editScope, excluding: selectedSnippet?.id
        ) {
            error = validationError
            return
        }

        if isCreatingNew {
            snippetService.addSnippet(
                trigger: editTrigger,
                replacement: editReplacement,
                caseSensitive: editCaseSensitive,
                scope: editScope
            )
        } else if let snippet = selectedSnippet {
            snippetService.updateSnippet(
                snippet,
                trigger: editTrigger,
                replacement: editReplacement,
                caseSensitive: editCaseSensitive,
                scope: editScope
            )
        }

        cancelEditing()
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippetService.deleteSnippet(snippet)
    }

    func toggleSnippet(_ snippet: Snippet) {
        snippetService.toggleSnippet(snippet)
    }

    func clearError() {
        error = nil
    }
}
