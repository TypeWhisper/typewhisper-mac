import Foundation

enum TestSupport {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let artifactsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypeWhisperTests-artifacts", isDirectory: true)
    private static let deferredCleanupRoot = artifactsRoot
        .appendingPathComponent(".deferred-cleanup", isDirectory: true)
    private static let staleDirectoryLifetime: TimeInterval = 24 * 60 * 60

    static func makeTemporaryDirectory(prefix: String = "TypeWhisperTests") throws -> URL {
        try ensureArtifactsDirectories()
        cleanupStaleDirectories()

        let directory = artifactsRoot
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        do {
            try ensureArtifactsDirectories()

            let standardizedDirectory = directory.standardizedFileURL
            let deferredRootPath = deferredCleanupRoot.standardizedFileURL.path
            let artifactsRootPath = artifactsRoot.standardizedFileURL.path

            guard standardizedDirectory.path.hasPrefix(artifactsRootPath),
                  !standardizedDirectory.path.hasPrefix(deferredRootPath) else {
                try FileManager.default.removeItem(at: standardizedDirectory)
                return
            }

            let destination = deferredCleanupRoot
                .appendingPathComponent("\(directory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: standardizedDirectory, to: destination)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func ensureArtifactsDirectories() throws {
        try FileManager.default.createDirectory(at: artifactsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deferredCleanupRoot, withIntermediateDirectories: true)
    }

    private static func cleanupStaleDirectories() {
        let cutoff = Date().addingTimeInterval(-staleDirectoryLifetime)
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey]

        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: deferredCleanupRoot,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: resourceKeys)
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            guard modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
