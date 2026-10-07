import Combine
import Foundation
import os

private let voiceProfileLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "VoiceProfiles")

/// Voice profiles and the speaker embeddings of recent meeting recordings.
///
/// Both are biometric data, so they live in one file outside History:
/// readable only by the user, excluded from backups, and never synced,
/// exported, or shared. Only speaker names reach History and sync.
@MainActor
final class VoiceProfileStore: ObservableObject {
    private struct Contents: Codable {
        var profiles: [VoiceProfile] = []
        var recordings: [UUID: RecordingSpeakerEmbeddings] = [:]
        var currentEmbeddingModel: String?
    }

    @Published private(set) var profiles: [VoiceProfile] = []
    /// The embedding model of the latest speaker detection. Profiles of
    /// another model are outdated: they no longer match until relearned.
    @Published private(set) var currentEmbeddingModel: String?
    private var recordings: [UUID: RecordingSpeakerEmbeddings] = [:]
    private let fileURL: URL
    private let now: () -> Date

    init(directoryURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        var directory = directoryURL ?? AppConstants.appSupportDirectory
            .appendingPathComponent("VoiceProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        fileURL = directory.appendingPathComponent("voice-profiles.json")
        self.now = now
        load()
    }

    func profile(withID id: UUID) -> VoiceProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Recording embeddings

    /// Embeddings of a recording's speakers, if they belong to its current transcript.
    func embeddings(forRecordID id: UUID, revision: UUID) -> [String: [Float]] {
        recording(id, revision: revision)?.embeddings ?? [:]
    }

    /// The model of a recording's embeddings, if they belong to its current transcript.
    func embeddingModel(forRecordID id: UUID, revision: UUID) -> String? {
        recording(id, revision: revision)?.embeddingModel
    }

    private func recording(_ id: UUID, revision: UUID) -> RecordingSpeakerEmbeddings? {
        guard let stored = recordings[id], stored.transcriptRevision == revision else { return nil }
        return stored
    }

    /// True when the profile was learned with another model than the latest
    /// speaker detection used, so it can't recognize anyone until relearned.
    func isOutdated(_ profile: VoiceProfile) -> Bool {
        profile.embeddingModel == nil || profile.embeddingModel != currentEmbeddingModel
    }

    /// Recordings whose speaker embeddings are stored, for matching new profiles.
    var recordingEmbeddings: [UUID: RecordingSpeakerEmbeddings] {
        recordings
    }

    /// Replaces the embeddings of a recording after a diarization run.
    func storeEmbeddings(_ embeddings: [String: [Float]], model: String, forRecordID id: UUID, revision: UUID) {
        recordings[id] = RecordingSpeakerEmbeddings(
            transcriptRevision: revision,
            embeddingModel: model,
            embeddings: embeddings
        )
        currentEmbeddingModel = model
        save()
    }

    /// Moves embeddings along when turns were moved or speakers merged.
    func transcriptCorrected(recordID id: UUID, from old: SpeakerTranscript, to new: SpeakerTranscript) {
        guard var stored = recordings[id], stored.transcriptRevision == old.revision else { return }
        stored.embeddings = VoiceProfileMatching.correctedEmbeddings(stored.embeddings, from: old, to: new)
        recordings[id] = stored
        save()
    }

    /// Drops the embeddings of deleted recordings.
    func removeEmbeddings(forRecordIDs removed: Set<UUID>) {
        guard recordings.keys.contains(where: removed.contains) else { return }
        recordings = recordings.filter { !removed.contains($0.key) }
        save()
    }

    /// Drops embeddings of recordings that no longer exist.
    func removeEmbeddings(exceptForRecordIDs kept: Set<UUID>) {
        let before = recordings.count
        recordings = recordings.filter { kept.contains($0.key) }
        if recordings.count != before { save() }
    }

    // MARK: - Profiles

    @discardableResult
    func enroll(name: String, embedding: [Float], model: String, seconds: TimeInterval) -> VoiceProfile {
        let date = now()
        let profile = VoiceProfile(
            id: UUID(),
            name: name,
            embedding: embedding,
            embeddingModel: model,
            enrolledSeconds: seconds,
            createdAt: date,
            updatedAt: date
        )
        profiles.append(profile)
        sortAndSave()
        return profile
    }

    /// Learns from a confirmed recognition, so the profile improves over time.
    /// A profile of another model can't be averaged with it and is replaced.
    func learn(profileID: UUID, embedding: [Float], model: String, seconds: TimeInterval) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard profiles[index].embeddingModel == model else {
            relearn(profileID: profileID, embedding: embedding, model: model, seconds: seconds)
            return
        }
        var profile = profiles[index]
        profile.embedding = VoiceProfileMatching.mean(
            profile.embedding, weight: profile.enrolledSeconds, embedding, weight: seconds
        )
        profile.enrolledSeconds += seconds
        profile.updatedAt = now()
        profiles[index] = profile
        save()
    }

    /// Replaces the voice with one learned from a single recording, when
    /// the old one came from poor audio or the wrong person.
    func relearn(profileID: UUID, embedding: [Float], model: String, seconds: TimeInterval) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].embedding = embedding
        profiles[index].embeddingModel = model
        profiles[index].enrolledSeconds = seconds
        profiles[index].updatedAt = now()
        save()
    }

    func profile(named name: String) -> VoiceProfile? {
        let key = SpeakerTranscriptPresentation.nameKey(name)
        return profiles.first { SpeakerTranscriptPresentation.nameKey($0.name) == key }
    }

    func rename(profileID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].name = String(trimmed.prefix(SpeakerNameTable.maximumNameLength))
        profiles[index].updatedAt = now()
        sortAndSave()
    }

    /// Removes the embedding; names already given in recordings stay.
    func delete(profileID: UUID) {
        profiles.removeAll { $0.id == profileID }
        save()
    }

    // MARK: - Storage

    private func sortAndSave() {
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            profiles = contents.profiles
            recordings = contents.recordings
            currentEmbeddingModel = contents.currentEmbeddingModel
        } catch {
            voiceProfileLogger.error("Voice profiles could not be read: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Contents(
                profiles: profiles,
                recordings: recordings,
                currentEmbeddingModel: currentEmbeddingModel
            ))
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            voiceProfileLogger.error("Voice profiles could not be saved: \(String(reflecting: error), privacy: .public)")
        }
    }
}
