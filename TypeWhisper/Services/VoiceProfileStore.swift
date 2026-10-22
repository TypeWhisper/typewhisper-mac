import Combine
import Darwin
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
        // Optional so stores written before enrollment receipts still decode.
        var learnedSamples: [LearnedSample]?
    }

    struct LearnedSample: Codable, Equatable {
        let recordID: UUID
        let revision: UUID
        /// Original sample label, independent of later transcript renumbering.
        let speakerID: String
        let profileID: UUID
    }

    enum LearningError: Error {
        case conflictingSample, partiallyLearned, missingProfile, incompatibleModel, invalidEmbedding, staleEmbeddings
    }

    @Published private(set) var profiles: [VoiceProfile] = []
    /// The embedding model of the latest speaker detection. Profiles of
    /// another model are outdated: they no longer match until relearned.
    @Published private(set) var currentEmbeddingModel: String?
    private var recordings: [UUID: RecordingSpeakerEmbeddings] = [:]
    private let fileURL: URL
    private let now: () -> Date
    private var learnedSamples: [LearnedSample] = []

    private func sources(recordID: UUID, revision: UUID, speakerID: String) -> Set<String> {
        guard let stored = recording(recordID, revision: revision) else { return [] }
        return Set(stored.sourceSpeakerIDs?[speakerID] ?? (stored.embeddings[speakerID] == nil ? [] : [speakerID]))
    }

    func learnedProfiles(recordID: UUID, revision: UUID, speakerID: String) -> Set<UUID> {
        let sourceIDs = sources(recordID: recordID, revision: revision, speakerID: speakerID)
        guard !sourceIDs.isEmpty else { return [] }
        let samples = learnedSamples.filter { $0.recordID == recordID && $0.revision == revision }
        return Set(samples.map(\.profileID)).filter { profileID in
            sourceIDs.isSubset(of: Set(samples.filter { $0.profileID == profileID }.map(\.speakerID)))
        }
    }

    func learnedProfile(recordID: UUID, revision: UUID, speakerID: String) -> UUID? {
        learnedProfiles(recordID: recordID, revision: revision, speakerID: speakerID).first
    }

    func hasLearning(recordID: UUID, revision: UUID, speakerID: String) -> Bool {
        let sourceIDs = sources(recordID: recordID, revision: revision, speakerID: speakerID)
        return learnedSamples.contains { $0.recordID == recordID && $0.revision == revision && sourceIDs.contains($0.speakerID) }
    }

    func hasCurrentEmbeddings(recordID: UUID, transcript: SpeakerTranscript) -> Bool {
        recording(recordID, revision: transcript.revision)?.transcriptVersion == transcript.automationVersion
    }

    /// Upgrade old confirmed links before a rename can erase their only evidence.
    /// Existing receipts are authoritative; a merged, partly learned sample must
    /// never be marked fully learned just because it inherited a profile link.
    func rememberConfirmedLinks(recordID: UUID, transcript: SpeakerTranscript, names: SpeakerNameTable?) throws {
        guard var stored = recording(recordID, revision: transcript.revision) else { return }
        let version = transcript.automationVersion
        guard stored.transcriptVersion == nil || stored.transcriptVersion == version else { return }
        let needsBinding = stored.transcriptVersion == nil || stored.sourceSpeakerIDs == nil
        if stored.sourceSpeakerIDs == nil {
            stored.sourceSpeakerIDs = Dictionary(uniqueKeysWithValues: stored.embeddings.keys.map { ($0, [$0]) })
        }
        stored.transcriptVersion = version
        var nextSamples = learnedSamples
        for entry in names?.confirmedEntries ?? [] {
            guard let profileID = entry.profileID, profile(withID: profileID) != nil,
                  let sourceIDs = stored.sourceSpeakerIDs?[entry.speakerID], !sourceIDs.isEmpty,
                  !nextSamples.contains(where: {
                      $0.recordID == recordID && $0.revision == transcript.revision && sourceIDs.contains($0.speakerID)
                  }) else { continue }
            nextSamples += sourceIDs.map {
                LearnedSample(recordID: recordID, revision: transcript.revision, speakerID: $0, profileID: profileID)
            }
        }
        guard needsBinding || nextSamples != learnedSamples else { return }
        var nextRecordings = recordings
        nextRecordings[recordID] = stored
        try persist(Contents(profiles: profiles, recordings: nextRecordings,
                             currentEmbeddingModel: currentEmbeddingModel, learnedSamples: nextSamples))
        recordings = nextRecordings
        learnedSamples = nextSamples
    }

    /// Commits the profile and its receipt in the same atomic file replacement.
    /// On failure the in-memory state also stays unchanged. Receipts survive
    /// profile deletion: replaying an old request must not resurrect a voice.
    func learnOnce(
        recordID: UUID, revision: UUID, speakerID: String, version: String,
        profileID: UUID?, name: String, embedding: [Float], model: String, seconds: TimeInterval,
        workspaceAssignment: Bool = false, replacing: Bool = false
    ) throws -> (profile: VoiceProfile, alreadyLearned: Bool) {
        guard let stored = recording(recordID, revision: revision), stored.transcriptVersion == version else {
            throw LearningError.staleEmbeddings
        }
        let sourceIDs = sources(recordID: recordID, revision: revision, speakerID: speakerID)
        guard !sourceIDs.isEmpty else { throw LearningError.invalidEmbedding }
        if let profileID, !replacing {
            let used = Set(learnedSamples.filter {
                $0.recordID == recordID && $0.revision == revision && $0.profileID == profileID
            }.map(\.speakerID))
            if sourceIDs.isSubset(of: used) {
                guard let previous = profile(withID: profileID) else { throw LearningError.missingProfile }
                return (previous, true)
            }
            guard sourceIDs.isDisjoint(with: used) else { throw LearningError.partiallyLearned }
        }
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite),
              embedding.contains(where: { $0 != 0 }), seconds.isFinite, seconds > 0 else {
            throw LearningError.invalidEmbedding
        }
        var nextProfiles = profiles
        let profile: VoiceProfile
        if let profileID {
            guard let index = nextProfiles.firstIndex(where: { $0.id == profileID }) else {
                throw LearningError.missingProfile
            }
            if replacing || nextProfiles[index].embeddingModel != model {
                guard workspaceAssignment else { throw LearningError.incompatibleModel }
                nextProfiles[index].embedding = embedding
                nextProfiles[index].embeddingModel = model
                nextProfiles[index].enrolledSeconds = seconds
            } else {
                guard nextProfiles[index].embedding.count == embedding.count else {
                    throw LearningError.incompatibleModel
                }
                nextProfiles[index].embedding = VoiceProfileMatching.mean(
                    nextProfiles[index].embedding, weight: nextProfiles[index].enrolledSeconds,
                    embedding, weight: seconds
                )
                nextProfiles[index].enrolledSeconds += seconds
            }
            nextProfiles[index].updatedAt = now()
            profile = nextProfiles[index]
        } else {
            profile = VoiceProfile(
                id: UUID(), name: name, embedding: embedding, embeddingModel: model,
                enrolledSeconds: seconds, createdAt: now(), updatedAt: now()
            )
            nextProfiles.append(profile)
        }
        let addedSamples = sourceIDs.sorted().map {
            LearnedSample(recordID: recordID, revision: revision, speakerID: $0, profileID: profile.id)
        }
        let nextSamples = learnedSamples + addedSamples.filter { !learnedSamples.contains($0) }
        nextProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try persist(Contents(
            profiles: nextProfiles, recordings: recordings, currentEmbeddingModel: currentEmbeddingModel,
            learnedSamples: nextSamples
        ))
        profiles = nextProfiles
        learnedSamples = nextSamples
        return (profile, false)
    }

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
    func storeEmbeddings(_ embeddings: [String: [Float]], model: String, forRecordID id: UUID, revision: UUID, version: String? = nil) {
        recordings[id] = RecordingSpeakerEmbeddings(
            transcriptRevision: revision,
            embeddingModel: model,
            embeddings: embeddings,
            transcriptVersion: version,
            sourceSpeakerIDs: Dictionary(uniqueKeysWithValues: embeddings.keys.map { ($0, [$0]) })
        )
        currentEmbeddingModel = model
        save()
    }

    /// Moves embeddings along when turns were moved or speakers merged.
    /// - Parameter saved: The embeddings stored for `new` before, when an undo
    ///   restores it. Moving along loses the voice of a speaker whose speech
    ///   went to several speakers in equal parts; the saved state still has it.
    func transcriptCorrected(
        recordID id: UUID,
        from old: SpeakerTranscript,
        to new: SpeakerTranscript,
        restoring saved: RecordingSpeakerEmbeddings? = nil
    ) {
        guard var stored = recordings[id], stored.transcriptRevision == old.revision,
              stored.transcriptVersion == nil || stored.transcriptVersion == old.automationVersion else { return }
        if let saved, saved.transcriptRevision == new.revision, saved.transcriptVersion == new.automationVersion {
            stored = saved
        } else {
            let originalSources = stored.sourceSpeakerIDs
                ?? Dictionary(uniqueKeysWithValues: stored.embeddings.keys.map { ($0, [$0]) })
            var movedSources: [String: Set<String>] = [:]
            for (oldID, newID) in VoiceProfileMatching.correctedSpeakerContributors(from: old, to: new) {
                guard stored.embeddings[oldID] != nil else { continue }
                movedSources[newID, default: []].formUnion(originalSources[oldID] ?? [])
            }
            stored.embeddings = VoiceProfileMatching.correctedEmbeddings(stored.embeddings, from: old, to: new)
            stored.sourceSpeakerIDs = movedSources.mapValues { $0.sorted() }
            stored.transcriptVersion = new.automationVersion
        }
        var nextRecordings = recordings
        nextRecordings[id] = stored
        do {
            try persist(Contents(profiles: profiles, recordings: nextRecordings,
                                 currentEmbeddingModel: currentEmbeddingModel, learnedSamples: learnedSamples))
            recordings = nextRecordings
        } catch {
            // History already contains the edit. Keep the old version stamp so
            // neither UI nor API can use mislabelled embeddings after a failure.
            voiceProfileLogger.error("Corrected voices could not be saved: \(error.localizedDescription)")
        }
    }

    var storedRecordIDs: Set<UUID> {
        Set(recordings.keys).union(learnedSamples.map(\.recordID))
    }

    /// Deleting a History entry also removes its enrollment provenance. Profile
    /// deletion alone keeps it, preventing old requests from recreating a voice.
    func removeEmbeddings(forRecordIDs removed: Set<UUID>) {
        removeEmbeddings(exceptForRecordIDs: storedRecordIDs.subtracting(removed))
    }

    func removeEmbeddings(exceptForRecordIDs kept: Set<UUID>) {
        let nextRecordings = recordings.filter { kept.contains($0.key) }
        let nextSamples = learnedSamples.filter { kept.contains($0.recordID) }
        guard nextRecordings.count != recordings.count || nextSamples.count != learnedSamples.count else { return }
        do {
            try persist(Contents(profiles: profiles, recordings: nextRecordings,
                                 currentEmbeddingModel: currentEmbeddingModel, learnedSamples: nextSamples))
            recordings = nextRecordings
            learnedSamples = nextSamples
        } catch {
            voiceProfileLogger.error("Deleted recording voices could not be removed: \(error.localizedDescription)")
        }
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
            learnedSamples = contents.learnedSamples ?? []
        } catch {
            voiceProfileLogger.error("Voice profiles could not be read: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func save() {
        do {
            try persist(Contents(
                profiles: profiles,
                recordings: recordings,
                currentEmbeddingModel: currentEmbeddingModel,
                learnedSamples: learnedSamples
            ))
        } catch {
            voiceProfileLogger.error("Voice profiles could not be saved: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func persist(_ contents: Contents) throws {
        let data = try JSONEncoder().encode(contents)
        // A private staging file carries restrictive permissions into the atomic
        // rename. No fallible operation follows the commit point.
        let staging = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        if Darwin.rename(staging.path, fileURL.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
