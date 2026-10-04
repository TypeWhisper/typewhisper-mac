import Foundation

/// What the workspace can do with one speaker's voice.
enum SpeakerVoiceState: Equatable {
    /// No profile and none can be made: unnamed, too little speech, or no stored voice.
    case none
    /// Named, with enough speech: a voice profile can be created.
    case canEnroll
    /// The name was recognized from a voice profile and waits for confirmation.
    case suggestion
    /// The speaker is linked to a voice profile.
    case linked
    /// The speaker is linked to a voice profile learned with an older model,
    /// which recognizes no one until it is relearned from this recording.
    case outdated
}

/// Recognizes named voices in recordings: keeps each recording's speaker
/// embeddings, suggests names from voice profiles, and creates or improves
/// profiles when the user asks for it. Everything here needs Premium; names
/// and profiles are kept without it.
@MainActor
final class SpeakerVoiceProfileService: ObservableObject {
    let store: VoiceProfileStore
    private let historyService: HistoryService
    private let premiumAccess: @MainActor () -> Bool

    init(
        store: VoiceProfileStore,
        historyService: HistoryService,
        premiumAccess: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.historyService = historyService
        self.premiumAccess = premiumAccess
    }

    // MARK: - After detection and corrections

    /// Keeps the speakers' embeddings for enrolling them later and suggests
    /// the names of recognized voice profiles.
    func recordVoices(
        _ embeddings: [String: [Float]],
        model: String,
        of transcript: SpeakerTranscript,
        recordID: UUID
    ) {
        guard premiumAccess() else { return }
        let speakerIDs = Set(transcript.speakerIDs)
        store.storeEmbeddings(
            embeddings.filter { speakerIDs.contains($0.key) },
            model: model,
            forRecordID: recordID,
            revision: transcript.revision
        )
        suggestNames(inRecordID: recordID)
    }

    /// Moves embeddings along when turns were moved or speakers merged.
    func transcriptCorrected(recordID: UUID, from old: SpeakerTranscript, to new: SpeakerTranscript) {
        store.transcriptCorrected(recordID: recordID, from: old, to: new)
    }

    /// Drops embeddings of recordings that were deleted.
    func removeEmbeddingsOfDeletedRecordings() {
        guard !store.recordingEmbeddings.isEmpty else { return }
        let kept = Set(store.recordingEmbeddings.keys.filter { historyService.record(withID: $0) != nil })
        store.removeEmbeddings(exceptForRecordIDs: kept)
    }

    /// Suggests voice profile names in every recording with stored
    /// embeddings, so earlier recordings of the same people get the name too.
    private func suggestNamesInStoredRecordings() {
        for recordID in store.recordingEmbeddings.keys {
            suggestNames(inRecordID: recordID)
        }
    }

    /// Matches the unnamed speakers of one recording against the profiles
    /// that no speaker of it uses yet. Names the user gave stay untouched.
    private func suggestNames(inRecordID recordID: UUID) {
        guard premiumAccess(),
              let record = historyService.record(withID: recordID),
              let transcript = record.speakerTranscript else { return }
        let names = record.speakerNames
        let embeddings = store.embeddings(forRecordID: recordID, revision: transcript.revision)
            .filter { names?.displayName(for: $0.key) == nil }
        let usedProfiles = Set(transcript.speakerIDs.compactMap { names?.profileID(for: $0) })
        let matches = VoiceProfileMatching.matches(
            speakers: embeddings,
            embeddingModel: store.embeddingModel(forRecordID: recordID, revision: transcript.revision),
            speakingTime: transcript.speakingTime(of:),
            profiles: store.profiles.filter { !usedProfiles.contains($0.id) }
        )
        for (speakerID, match) in matches {
            guard let profile = store.profile(withID: match.profileID) else { continue }
            historyService.setSpeakerName(
                profile.name,
                for: speakerID,
                profileID: profile.id,
                isSuggestion: true,
                inRecordID: recordID
            )
        }
    }

    // MARK: - One speaker

    func state(of speakerID: String, inRecordID recordID: UUID) -> SpeakerVoiceState {
        guard let record = historyService.record(withID: recordID),
              let transcript = record.speakerTranscript else { return .none }
        let names = record.speakerNames
        // A link synced from another device points to a profile that only
        // exists there; here the name is an ordinary name that can get a
        // profile of its own.
        if let profileID = names?.profileID(for: speakerID), let profile = store.profile(withID: profileID) {
            if names?.isSuggestion(for: speakerID) == true { return .suggestion }
            let canRelearn = voice(of: speakerID, inRecordID: recordID) != nil
            return store.isOutdated(profile) && canRelearn ? .outdated : .linked
        }
        guard transcript.speakingTime(of: speakerID) >= VoiceProfileMatching.minimumSpeechSeconds,
              voice(of: speakerID, inRecordID: recordID) != nil else {
            return .none
        }
        return .canEnroll
    }

    /// A named speaker's voice in this recording. Only embeddings of the
    /// current model count, so an older recording can't put an outdated
    /// voice into a profile.
    private func voice(
        of speakerID: String,
        inRecordID recordID: UUID
    ) -> (name: String, profileID: UUID?, embedding: [Float], model: String, seconds: TimeInterval)? {
        guard premiumAccess(),
              let record = historyService.record(withID: recordID),
              let transcript = record.speakerTranscript,
              let name = record.speakerNames?.displayName(for: speakerID),
              let model = store.embeddingModel(forRecordID: recordID, revision: transcript.revision),
              model == store.currentEmbeddingModel,
              let embedding = store.embeddings(forRecordID: recordID, revision: transcript.revision)[speakerID] else {
            return nil
        }
        return (
            name,
            record.speakerNames?.profileID(for: speakerID),
            embedding,
            model,
            transcript.speakingTime(of: speakerID)
        )
    }

    /// Creates a voice profile for a named speaker. A person enrolled again
    /// under the same name improves their profile instead of getting a second one.
    func enroll(_ speakerID: String, inRecordID recordID: UUID) {
        guard state(of: speakerID, inRecordID: recordID) == .canEnroll,
              let voice = voice(of: speakerID, inRecordID: recordID) else { return }
        let profileID: UUID
        if let existing = store.profile(named: voice.name) {
            store.learn(profileID: existing.id, embedding: voice.embedding, model: voice.model, seconds: voice.seconds)
            profileID = existing.id
        } else {
            profileID = store.enroll(
                name: voice.name,
                embedding: voice.embedding,
                model: voice.model,
                seconds: voice.seconds
            ).id
        }
        historyService.setSpeakerName(voice.name, for: speakerID, profileID: profileID, inRecordID: recordID)
        suggestNamesInStoredRecordings()
    }

    /// Confirms a recognized name; the profile learns from this recording.
    func confirm(_ speakerID: String, inRecordID recordID: UUID) {
        guard state(of: speakerID, inRecordID: recordID) == .suggestion,
              let voice = voice(of: speakerID, inRecordID: recordID),
              let profileID = voice.profileID else { return }
        store.learn(profileID: profileID, embedding: voice.embedding, model: voice.model, seconds: voice.seconds)
        historyService.setSpeakerName(voice.name, for: speakerID, profileID: profileID, inRecordID: recordID)
        suggestNamesInStoredRecordings()
    }

    /// Rejects a recognized name; the profile stays as it is.
    func reject(_ speakerID: String, inRecordID recordID: UUID) {
        guard state(of: speakerID, inRecordID: recordID) == .suggestion else { return }
        historyService.setSpeakerName("", for: speakerID, inRecordID: recordID)
    }

    /// Replaces the profile's voice with this recording's, when the old one
    /// came from poor audio, the wrong person, or an older model.
    func relearn(_ speakerID: String, inRecordID recordID: UUID) {
        guard [.linked, .outdated].contains(state(of: speakerID, inRecordID: recordID)),
              let voice = voice(of: speakerID, inRecordID: recordID),
              let profileID = voice.profileID else { return }
        store.relearn(profileID: profileID, embedding: voice.embedding, model: voice.model, seconds: voice.seconds)
        suggestNamesInStoredRecordings()
    }

    // MARK: - Profiles

    /// Renames a voice profile and the speakers linked to it in every recording.
    func renameProfile(_ profileID: UUID, to name: String) {
        store.rename(profileID: profileID, to: name)
        guard let renamed = store.profile(withID: profileID)?.name else { return }
        historyService.renameSpeakers(linkedTo: profileID, to: renamed)
    }

    /// Removes the voice; names already given in recordings stay.
    func deleteProfile(_ profileID: UUID) {
        store.delete(profileID: profileID)
    }

    /// Recordings where a speaker is linked to the profile, newest first.
    func appearances(of profileID: UUID) -> [VoiceProfileAppearance] {
        historyService.recordsWithSpeakerNames().compactMap { record in
            guard let transcript = record.speakerTranscript,
                  let entry = record.speakerNames?.entries.first(where: { $0.profileID == profileID }) else {
                return nil
            }
            return VoiceProfileAppearance(
                recordID: record.id,
                title: record.appName ?? record.source.displayName,
                date: record.timestamp,
                isSuggestion: entry.isSuggestion == true,
                turns: SpeakerTranscriptPresentation.turns(of: transcript).filter { $0.speakerID == entry.speakerID }
            )
        }
    }
}
