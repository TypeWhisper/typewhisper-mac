import Foundation
import AppKit
import Combine

@MainActor
final class WatchFolderViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: WatchFolderViewModel?
    static var shared: WatchFolderViewModel {
        guard let instance = _shared else {
            fatalError("WatchFolderViewModel not initialized")
        }
        return instance
    }

    @Published var watchFolderPath: String?
    @Published var outputFolderPath: String?
    @Published var outputFormat: String = "md" {
        didSet { UserDefaults.standard.set(outputFormat, forKey: UserDefaultsKeys.watchFolderOutputFormat) }
    }
    @Published var deleteSourceFiles: Bool = false {
        didSet { UserDefaults.standard.set(deleteSourceFiles, forKey: UserDefaultsKeys.watchFolderDeleteSource) }
    }
    @Published var autoStartOnLaunch: Bool = false {
        didSet { UserDefaults.standard.set(autoStartOnLaunch, forKey: UserDefaultsKeys.watchFolderAutoStart) }
    }
    @Published var language: String? {
        didSet { UserDefaults.standard.set(language, forKey: UserDefaultsKeys.watchFolderLanguage) }
    }

    let watchFolderService: WatchFolderService

    init(watchFolderService: WatchFolderService) {
        self.watchFolderService = watchFolderService
        loadSettings()
    }

    func selectWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "watchFolder.selectFolder.message")

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.watchFolderBookmark)
                watchFolderPath = url.path
            }
        }
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "watchFolder.selectOutputFolder.message")

        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: UserDefaultsKeys.watchFolderOutputBookmark)
                outputFolderPath = url.path
            }
        }
    }

    func clearOutputFolder() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.watchFolderOutputBookmark)
        outputFolderPath = nil
    }

    func toggleWatching() {
        if watchFolderService.isWatching {
            watchFolderService.stopWatching()
        } else if let url = resolveWatchFolderURL() {
            watchFolderService.startWatching(folderURL: url)
        }
    }

    // MARK: - Private

    private func loadSettings() {
        outputFormat = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderOutputFormat) ?? "md"
        deleteSourceFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderDeleteSource)
        autoStartOnLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.watchFolderAutoStart)
        language = UserDefaults.standard.string(forKey: UserDefaultsKeys.watchFolderLanguage)

        // Resolve watch folder bookmark
        if let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                watchFolderPath = url.path
            }
        }

        // Resolve output folder bookmark
        if let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderOutputBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale) {
                outputFolderPath = url.path
            }
        }
    }

    private func resolveWatchFolderURL() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: UserDefaultsKeys.watchFolderBookmark) else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
    }
}
