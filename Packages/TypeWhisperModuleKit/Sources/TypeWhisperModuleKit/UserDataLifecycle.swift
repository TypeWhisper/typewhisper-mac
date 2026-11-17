import Foundation

/// Gives a module a folder for its files and lets it erase and export its
/// own data with the user's data.
///
/// Data a module keeps in the app's preferences or in `dataFolder(forModuleID:)`
/// is erased and exported with them anyway. Register for data kept anywhere
/// else, or for data that needs its own export format.
@MainActor
public protocol UserDataLifecycle: AnyObject {
    /// The folder for a module's files, `Modules/<id>/` in the app's
    /// Application Support folder, created if needed. Each edition and the
    /// development build of the app has its own. Erasing all data deletes it,
    /// and a data export contains it.
    ///
    /// - Parameter id: Letters, digits, dots, hyphens and underscores, at most
    ///   128 characters, like `ModuleUserData.id`. Identifiers that differ only
    ///   in case can share a folder.
    /// - Throws: For another identifier, or when the folder cannot be created.
    func dataFolder(forModuleID id: String) throws -> URL

    /// Registers a module's data. A later registration with the same
    /// identifier replaces the earlier one.
    func register(_ userData: ModuleUserData)
}

/// How the app erases and exports one module's data.
public struct ModuleUserData: Identifiable, Sendable {
    /// Also the folder of the exported files, so letters, digits, dots,
    /// hyphens and underscores only, at most 128 characters.
    public let id: String
    /// Runs when the user erases all data, before the app deletes its own.
    public let erase: @MainActor @Sendable () async throws -> Void
    /// Returns the files to add to a data export, by file name. A name with a
    /// path separator is left out; names that differ only in case fail the export.
    public let export: @MainActor @Sendable () async throws -> [String: Data]

    public init(
        id: String,
        erase: @escaping @MainActor @Sendable () async throws -> Void,
        export: @escaping @MainActor @Sendable () async throws -> [String: Data]
    ) {
        self.id = id
        self.erase = erase
        self.export = export
    }
}
