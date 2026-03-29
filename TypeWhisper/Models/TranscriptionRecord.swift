import Foundation
import SwiftData

@Model
final class TranscriptionRecord {
    var id: UUID
    var timestamp: Date
    var rawText: String
    var finalText: String
    var appName: String?
    var appBundleIdentifier: String?
    var appURL: String?
    var durationSeconds: Double
    var language: String?
    var engineUsed: String
    var modelUsed: String?
    var wordsCount: Int = 0
    var audioFileName: String?
    var pipelineSteps: String?

    var preview: String { String(finalText.prefix(100)) }

    var wasPostProcessed: Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines) != finalText
    }
    var pipelineStepList: [String] {
        get {
            guard let pipelineSteps, !pipelineSteps.isEmpty else { return [] }
            if let data = pipelineSteps.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded
            }
            return pipelineSteps
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            guard !newValue.isEmpty else {
                pipelineSteps = nil
                return
            }
            if let data = try? JSONEncoder().encode(newValue),
               let encoded = String(data: data, encoding: .utf8) {
                pipelineSteps = encoded
            } else {
                pipelineSteps = newValue.joined(separator: ",")
            }
        }
    }

    /// Extracts the domain from appURL (e.g. "https://github.com/foo" → "github.com")
    var appDomain: String? {
        guard let urlString = appURL,
              let url = URL(string: urlString),
              let host = url.host() else { return nil }
        return host
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        finalText: String,
        appName: String? = nil,
        appBundleIdentifier: String? = nil,
        appURL: String? = nil,
        durationSeconds: Double,
        language: String? = nil,
        engineUsed: String,
        modelUsed: String? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.finalText = finalText
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appURL = appURL
        self.durationSeconds = durationSeconds
        self.language = language
        self.engineUsed = engineUsed
        self.modelUsed = modelUsed
        self.wordsCount = finalText.split(separator: " ").count
        self.audioFileName = audioFileName
    }
}
