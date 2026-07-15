import Foundation

/// Deterministic key encoding used by `UsageStatisticsDay` to persist per-app and per-model
/// breakdowns alongside the existing daily aggregates. Keeping this logic in one place lets both
/// the persistence layer (`UsageStatisticsDay`) and the view layer (`StatisticsViewModel`) agree
/// on how a transcription's app/model identity is turned into a stable dictionary key and back.
enum UsageStatisticsKeys {
    /// Builds a stable key for an app usage bucket. Prefers the bundle identifier (stable across
    /// launches/renames); falls back to the app's display name when no bundle identifier is
    /// available, and finally to a shared "unknown" bucket.
    static func appKey(bundleIdentifier: String?, appName: String?) -> String {
        if let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "b:\(id)"
        }
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "n:\(name)"
        }
        return "unknown"
    }

    /// Recovers what we know about an app usage key: the bundle identifier when the key was built
    /// from one, or a fallback display name when it wasn't.
    static func parseAppKey(_ key: String) -> (bundleIdentifier: String?, fallbackName: String?) {
        if key.hasPrefix("b:") {
            return (String(key.dropFirst(2)), nil)
        }
        if key.hasPrefix("n:") {
            return (nil, String(key.dropFirst(2)))
        }
        return (nil, nil)
    }

    /// Builds a stable key for a model/engine usage bucket.
    static func modelKey(engineUsed: String, modelUsed: String?) -> String {
        let trimmedModel = modelUsed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedModel.isEmpty, trimmedModel != engineUsed else { return engineUsed }
        return "\(engineUsed)||\(trimmedModel)"
    }

    /// Recovers the engine identifier and optional model name from a model usage key.
    static func parseModelKey(_ key: String) -> (engineUsed: String, modelUsed: String?) {
        guard let range = key.range(of: "||") else { return (key, nil) }
        let engineUsed = String(key[key.startIndex..<range.lowerBound])
        let modelUsed = String(key[range.upperBound...])
        return (engineUsed, modelUsed.isEmpty ? nil : modelUsed)
    }
}
