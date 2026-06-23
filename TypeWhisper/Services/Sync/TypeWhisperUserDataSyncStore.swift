import Combine
import Foundation

@MainActor
final class TypeWhisperUserDataSyncStore: UserDataSyncStore, @unchecked Sendable {
    private let dictionaryService: DictionaryService
    private let snippetService: SnippetService
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var observers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var isApplyingRemoteChanges = false

    init(
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        defaults: UserDefaults = .standard
    ) {
        self.dictionaryService = dictionaryService
        self.snippetService = snippetService
        self.defaults = defaults

        dictionaryService.$entries
            .dropFirst()
            .sink { [weak self] _ in
                self?.notifyLocalChange()
            }
            .store(in: &cancellables)

        snippetService.$snippets
            .dropFirst()
            .sink { [weak self] _ in
                self?.notifyLocalChange()
            }
            .store(in: &cancellables)
    }

    func snapshot() -> UserDataSyncSnapshot {
        let excluded = managedDictionaryItemIDs()
        return UserDataSyncSnapshot(
            dictionaryEntries: dictionaryService.userDataSyncEntries(
                excludingTermItemIDs: excluded.terms,
                excludingCorrectionItemIDs: excluded.corrections
            ),
            snippets: snippetService.userDataSyncSnippets()
        )
    }

    func apply(_ mutations: [UserDataSyncMutation]) throws {
        guard !mutations.isEmpty else { return }
        isApplyingRemoteChanges = true
        defer { isApplyingRemoteChanges = false }

        try dictionaryService.applyUserDataSyncMutations(mutations)
        try snippetService.applyUserDataSyncMutations(mutations)
    }

    @discardableResult
    func observeLocalChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeLocalChangeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyLocalChange() {
        guard !isApplyingRemoteChanges else { return }
        let handlers = Array(observers.values)
        for handler in handlers {
            handler()
        }
    }

    private func managedDictionaryItemIDs() -> (terms: Set<String>, corrections: Set<String>) {
        guard let data = defaults.data(forKey: UserDefaultsKeys.activatedTermPackStates),
              let states = try? JSONDecoder().decode([ActivatedTermPackState].self, from: data) else {
            return ([], [])
        }

        var termIDs = Set<String>()
        var correctionIDs = Set<String>()

        for state in states {
            for term in state.installedTerms {
                termIDs.insert(UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: term))
            }
            for correction in state.installedCorrections {
                correctionIDs.insert(UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: correction.original))
            }
        }

        return (termIDs, correctionIDs)
    }
}
