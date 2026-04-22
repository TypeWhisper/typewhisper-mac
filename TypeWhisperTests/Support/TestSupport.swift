import Foundation
import XCTest

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

    static func localizedCatalogValue(for key: String, language: String) throws -> String {
        let localizations = try catalogLocalizations(for: key)
        let languageEntry = try XCTUnwrap(
            localizations[language] as? [String: Any],
            "Missing \(language) localization for key: \(key)"
        )
        let stringUnit = try XCTUnwrap(
            languageEntry["stringUnit"] as? [String: Any],
            "Missing stringUnit for key: \(key)"
        )
        return try XCTUnwrap(
            stringUnit["value"] as? String,
            "Missing localized value for key: \(key)"
        )
    }

    static func localizedCatalogValue(for key: String, preferredLanguages: [String]) throws -> String {
        let localizations = try catalogLocalizations(for: key)

        for language in normalizedLanguageCandidates(from: preferredLanguages) {
            guard let languageEntry = localizations[language] as? [String: Any],
                  let stringUnit = languageEntry["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String else {
                continue
            }
            return value
        }

        return key
    }

    static func localizedCatalogValueForCurrentLocale(for key: String, bundle: Bundle = .main) throws -> String {
        try localizedCatalogValue(
            for: key,
            preferredLanguages: bundle.preferredLocalizations + Locale.preferredLanguages
        )
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

    private static func catalogLocalizations(for key: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("TypeWhisper/Resources/Localizable.xcstrings"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry for key: \(key)")
        return try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for key: \(key)")
    }

    private static func normalizedLanguageCandidates(from identifiers: [String]) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ identifier: String) {
            guard !identifier.isEmpty, seen.insert(identifier).inserted else { return }
            candidates.append(identifier)
        }

        for identifier in identifiers {
            append(identifier)

            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            append(normalized)

            if let languageCode = normalized.split(separator: "-").first {
                append(String(languageCode))
            }
        }

        append("en")
        return candidates
    }
}
