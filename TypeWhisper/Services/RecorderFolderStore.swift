import Combine
import Foundation
import os

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "RecorderFolderStore")

/// A folder the Recorder saves recordings to, or saved them to before.
struct RecorderFolder: Codable, Equatable, Sendable {
    /// Security-scoped bookmark of a folder the user chose; `nil` stands for the default folder.
    var bookmark: Data?
    /// The folder's path when it was last found, shown while the bookmark cannot be resolved.
    var path: String

    var isDefault: Bool { bookmark == nil }
}

/// Creates and resolves the bookmarks that keep a chosen Recorder folder usable after a relaunch.
/// The App Store edition can only reopen a folder outside its container through such a bookmark.
protocol RecorderFolderBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
    /// Returns `false` when the folder's security scope could not be entered.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SecurityScopedRecorderFolderBookmarks: RecorderFolderBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        // A disconnected disk or server counts as unavailable; it is neither mounted nor asked
        // for credentials. Access starts explicitly, so every start has a matching stop.
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Where the Recorder saves new recordings and which folders it lists.
///
/// New recordings go to the folder the user chose, or to the default folder. Recordings stay where
/// they were saved: the previous folder moves to `earlierFolders`, and the Recorder keeps listing
/// its recordings until the user removes it there. A chosen folder that cannot be used (disk
/// disconnected, folder deleted or in the Trash, access refused, read-only) never blocks or loses a
/// recording: it is saved to the default folder instead, and `notice` says so.
///
/// The recorder service resolves folders off the main actor, so the store is thread-safe. Its
/// settings change on the main thread, and changes are published there.
final class RecorderFolderStore: ObservableObject, @unchecked Sendable {
    enum Notice: Equatable, Sendable {
        /// The chosen folder cannot be used; new recordings go to the default folder.
        case unavailable(path: String)
        /// A recording could not be saved to this folder and went to the default folder.
        case saveFailed(path: String)
    }

    enum ChoiceError: LocalizedError, Equatable {
        case notWritable(path: String)
        /// The Watch Folder would transcribe each new recording again and, when it deletes
        /// source files, delete the recording.
        case watchFolder(path: String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let path):
                String(
                    format: String(localized: "recorder.folder.error.notWritable"),
                    RecorderFolderStore.folderName(of: path)
                )
            case .watchFolder(let path):
                String(
                    format: String(localized: "recorder.folder.error.watchFolder"),
                    RecorderFolderStore.folderName(of: path)
                )
            }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AudioRecorderService.recordingsDirectoryName, isDirectory: true)
    }

    /// The App Store sandbox refuses a chosen folder unless its security scope was entered.
    static var requiresSecurityScope: Bool {
        #if APPSTORE
        true
        #else
        false
        #endif
    }

    let defaultDirectory: URL
    private let defaults: UserDefaults
    private let bookmarks: any RecorderFolderBookmarking
    private let requiresSecurityScope: Bool

    private struct State {
        /// Folders whose security scope this store entered, by `folderKey`.
        var accessedFolders: [String: URL] = [:]
        var unavailableFolderPath: String?
        var failedSaveFolderPath: String?
    }

    /// Also serializes changes to the folder settings in `defaults`.
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        defaults: UserDefaults = .standard,
        defaultDirectory: URL = RecorderFolderStore.defaultDirectory,
        bookmarks: any RecorderFolderBookmarking = SecurityScopedRecorderFolderBookmarks(),
        requiresSecurityScope: Bool = RecorderFolderStore.requiresSecurityScope
    ) {
        self.defaults = defaults
        self.defaultDirectory = defaultDirectory
        self.bookmarks = bookmarks
        self.requiresSecurityScope = requiresSecurityScope
    }

    deinit {
        for url in state.withLock({ $0.accessedFolders.values }) {
            bookmarks.stopAccessing(url)
        }
    }

    // MARK: - Settings

    /// The folder the user chose for new recordings; `nil` while they go to the default folder.
    var chosenFolder: RecorderFolder? {
        state.withLock { _ in storedChosenFolder() }
    }

    /// Folders recordings were saved to before, most recent first.
    var earlierFolders: [RecorderFolder] {
        state.withLock { _ in storedEarlierFolders() }
    }

    var usesDefaultFolder: Bool { chosenFolder == nil }

    /// Path of the folder new recordings are meant to go to, also while it is unavailable.
    var chosenFolderPath: String { chosenFolder?.path ?? defaultDirectory.path }

    func path(of folder: RecorderFolder) -> String {
        folder.isDefault ? defaultDirectory.path : folder.path
    }

    var notice: Notice? {
        state.withLock { state in
            if let path = state.unavailableFolderPath { return .unavailable(path: path) }
            if let path = state.failedSaveFolderPath { return .saveFailed(path: path) }
            return nil
        }
    }

    /// Saves new recordings to `url` from now on. Recordings already saved stay where they are,
    /// and the previous folder stays listed. The folder the Watch Folder watches is refused.
    func chooseFolder(_ url: URL, watchFolderPath: String? = nil) throws {
        let url = url.standardizedFileURL
        if Self.isSameFolder(url, defaultDirectory) {
            useDefaultFolder()
            return
        }
        if let watchFolderPath, Self.isSameFolder(url.path, watchFolderPath) {
            throw ChoiceError.watchFolder(path: url.path)
        }
        guard Self.isUsableDirectory(url, forWriting: true) else {
            throw ChoiceError.notWritable(path: url.path)
        }
        let bookmark = try bookmarks.makeBookmark(for: url)
        let chosen = RecorderFolder(bookmark: bookmark, path: url.path)
        // Recordings saved before a folder was chosen are in the default folder.
        let keepsDefaultFolder = usesDefaultFolder && Self.containsFiles(defaultDirectory)

        state.withLock { state in
            var earlier = storedEarlierFolders()
            if let previous = storedChosenFolder() {
                earlier.insert(previous, at: 0)
            } else if keepsDefaultFolder {
                earlier.insert(RecorderFolder(bookmark: nil, path: defaultDirectory.path), at: 0)
            }
            earlier.removeAll { Self.isSameFolder(path(of: $0), url.path) }
            storeChosenFolder(chosen)
            storeEarlierFolders(deduplicated(earlier))
            state.unavailableFolderPath = nil
            state.failedSaveFolderPath = nil
        }
        notifyChange()
    }

    /// Saves new recordings to the default folder again; the chosen folder stays listed.
    func useDefaultFolder() {
        let changed = state.withLock { state -> Bool in
            guard let chosen = storedChosenFolder() else { return false }
            var earlier = storedEarlierFolders()
            earlier.removeAll(where: \.isDefault)
            earlier.insert(chosen, at: 0)
            storeChosenFolder(nil)
            storeEarlierFolders(deduplicated(earlier))
            state.unavailableFolderPath = nil
            state.failedSaveFolderPath = nil
            return true
        }
        if changed { notifyChange() }
    }

    /// Stops listing an earlier folder. Its recordings stay on disk.
    func forgetEarlierFolder(_ folder: RecorderFolder) {
        // Matched by path: the folder's bookmark may have been renewed since the list was shown.
        let removed = state.withLock { _ -> RecorderFolder? in
            var earlier = storedEarlierFolders()
            guard let index = earlier.firstIndex(where: { Self.isSameFolder(path(of: $0), path(of: folder)) }) else {
                return nil
            }
            let removed = earlier.remove(at: index)
            storeEarlierFolders(earlier)
            return removed
        }
        guard let removed else { return }
        let removedPath = path(of: removed)
        if !removed.isDefault, !Self.isSameFolder(removedPath, chosenFolderPath) {
            releaseAccess(toFolderAt: removedPath)
        }
        notifyChange()
    }

    // MARK: - Resolution

    /// The folder a new recording is saved to: the chosen folder, or the default folder while the
    /// chosen one cannot be used.
    func destinationForNewRecordings() -> URL {
        guard let chosen = chosenFolder else {
            setUnavailableFolderPath(nil)
            return defaultDirectory
        }
        if let url = usableURL(for: chosen, forWriting: true) {
            setUnavailableFolderPath(nil)
            return url
        }
        logger.warning("The chosen Recorder folder is unavailable; new recordings go to the default folder")
        setUnavailableFolderPath(chosen.path)
        return defaultDirectory
    }

    /// Checks again whether the chosen folder can be used, for example when the Recorder appears.
    func refreshAvailability() {
        _ = destinationForNewRecordings()
    }

    /// Folders whose recordings the Recorder lists: the chosen (or default) folder first, then
    /// earlier folders that can be read.
    func listedFolders() -> [URL] {
        var folders: [URL] = []
        if let chosen = chosenFolder {
            if let url = usableURL(for: chosen, forWriting: false) { folders.append(url) }
        } else {
            folders.append(defaultDirectory)
        }
        for folder in earlierFolders {
            if let url = usableURL(for: folder, forWriting: false) { folders.append(url) }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert(Self.folderKey($0.path)).inserted }
    }

    /// After a recording could not be saved in `directory`, for example because its disk was
    /// disconnected during the recording: the default folder to save it to instead, or `nil` when
    /// `directory` is the default folder.
    func fallbackDirectory(afterFailureIn directory: URL) -> URL? {
        guard !Self.isSameFolder(directory, defaultDirectory) else { return nil }
        let changed = state.withLock { state -> Bool in
            guard state.failedSaveFolderPath != directory.path else { return false }
            state.failedSaveFolderPath = directory.path
            return true
        }
        if changed { notifyChange() }
        return defaultDirectory
    }

    /// Records where a recording was saved. Recordings saved to the default folder while another
    /// folder is chosen stay listed after that folder is back.
    func noteRecordingSaved(at url: URL) {
        let directory = url.deletingLastPathComponent()
        let changed = state.withLock { state -> Bool in
            guard let chosen = storedChosenFolder() else { return false }
            if Self.isSameFolder(directory, defaultDirectory) {
                var earlier = storedEarlierFolders()
                guard !earlier.contains(where: \.isDefault) else { return false }
                earlier.insert(RecorderFolder(bookmark: nil, path: defaultDirectory.path), at: 0)
                storeEarlierFolders(earlier)
                return true
            }
            guard Self.isSameFolder(directory.path, chosen.path), state.failedSaveFolderPath != nil else {
                return false
            }
            state.failedSaveFolderPath = nil
            return true
        }
        if changed { notifyChange() }
    }

    // MARK: - Paths

    /// `path` with the home folder shortened to `~`.
    static func abbreviatedPath(_ path: String) -> String {
        let home = homeDirectoryPath
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func folderName(of path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The user's home folder. In the App Store sandbox `NSHomeDirectory()` is the app container,
    /// which would make paths inside it look like paths in the home folder.
    private static let homeDirectoryPath: String = {
        #if APPSTORE
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return String(cString: directory)
        }
        #endif
        return NSHomeDirectory()
    }()

    static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        isSameFolder(lhs.path, rhs.path)
    }

    static func isSameFolder(_ lhs: String, _ rhs: String) -> Bool {
        folderKey(lhs) == folderKey(rhs)
    }

    private static func folderKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isUsableDirectory(_ url: URL, forWriting: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // A bookmark follows a folder into the Trash.
        guard !url.resolvingSymlinksInPath().pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else {
            return false
        }
        return !forWriting || FileManager.default.isWritableFile(atPath: url.path)
    }

    private static func containsFiles(_ directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { !$0.hasPrefix(".") }
    }

    // MARK: - Private

    /// The folder for `folder` if it exists and can be used, entering its security scope.
    private func usableURL(for folder: RecorderFolder, forWriting: Bool) -> URL? {
        guard let bookmark = folder.bookmark else { return defaultDirectory }

        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try bookmarks.resolveBookmark(bookmark)
        } catch {
            logger.warning("Could not resolve a Recorder folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let url = resolved.url
        guard enterSecurityScope(of: url) else {
            logger.warning("The sandbox refused access to a Recorder folder")
            return nil
        }
        guard Self.isUsableDirectory(url, forWriting: forWriting) else { return nil }
        if resolved.isStale || !Self.isSameFolder(url.path, folder.path) {
            refresh(folder, resolvedURL: url)
        }
        return url
    }

    private func enterSecurityScope(of url: URL) -> Bool {
        let key = Self.folderKey(url.path)
        if state.withLock({ $0.accessedFolders[key] != nil }) { return true }
        guard bookmarks.startAccessing(url) else { return !requiresSecurityScope }
        let alreadyEntered = state.withLock { state -> Bool in
            if state.accessedFolders[key] != nil { return true }
            state.accessedFolders[key] = url
            return false
        }
        if alreadyEntered { bookmarks.stopAccessing(url) }
        return true
    }

    private func releaseAccess(toFolderAt path: String) {
        let url = state.withLock { $0.accessedFolders.removeValue(forKey: Self.folderKey(path)) }
        if let url { bookmarks.stopAccessing(url) }
    }

    /// Stores the folder's new bookmark and path after it was moved or renamed.
    private func refresh(_ folder: RecorderFolder, resolvedURL url: URL) {
        let bookmark: Data
        do {
            bookmark = try bookmarks.makeBookmark(for: url)
        } catch {
            logger.warning("Could not renew a Recorder folder bookmark: \(error.localizedDescription, privacy: .public)")
            return
        }
        let renewed = RecorderFolder(bookmark: bookmark, path: url.path)
        let changed = state.withLock { _ -> Bool in
            if storedChosenFolder() == folder {
                storeChosenFolder(renewed)
                return true
            }
            var earlier = storedEarlierFolders()
            guard let index = earlier.firstIndex(of: folder) else { return false }
            earlier[index] = renewed
            storeEarlierFolders(earlier)
            return true
        }
        if changed { notifyChange() }
    }

    private func setUnavailableFolderPath(_ path: String?) {
        let changed = state.withLock { state -> Bool in
            guard state.unavailableFolderPath != path else { return false }
            state.unavailableFolderPath = path
            return true
        }
        if changed { notifyChange() }
    }

    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    private func deduplicated(_ folders: [RecorderFolder]) -> [RecorderFolder] {
        var seen = Set<String>()
        return folders.filter { seen.insert(Self.folderKey(path(of: $0))).inserted }
    }

    // Call these only while holding `state`.

    private func storedChosenFolder() -> RecorderFolder? {
        guard let bookmark = defaults.data(forKey: UserDefaultsKeys.recorderFolderBookmark) else { return nil }
        return RecorderFolder(bookmark: bookmark, path: defaults.string(forKey: UserDefaultsKeys.recorderFolderPath) ?? "")
    }

    private func storeChosenFolder(_ folder: RecorderFolder?) {
        if let folder, let bookmark = folder.bookmark {
            defaults.set(bookmark, forKey: UserDefaultsKeys.recorderFolderBookmark)
            defaults.set(folder.path, forKey: UserDefaultsKeys.recorderFolderPath)
        } else {
            defaults.removeObject(forKey: UserDefaultsKeys.recorderFolderBookmark)
            defaults.removeObject(forKey: UserDefaultsKeys.recorderFolderPath)
        }
    }

    private func storedEarlierFolders() -> [RecorderFolder] {
        guard let data = defaults.data(forKey: UserDefaultsKeys.recorderEarlierFolders) else { return [] }
        do {
            return try JSONDecoder().decode([RecorderFolder].self, from: data)
        } catch {
            logger.error("Could not read the earlier Recorder folders: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func storeEarlierFolders(_ folders: [RecorderFolder]) {
        guard !folders.isEmpty else {
            defaults.removeObject(forKey: UserDefaultsKeys.recorderEarlierFolders)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(folders), forKey: UserDefaultsKeys.recorderEarlierFolders)
        } catch {
            logger.error("Could not save the earlier Recorder folders: \(error.localizedDescription, privacy: .public)")
        }
    }
}
