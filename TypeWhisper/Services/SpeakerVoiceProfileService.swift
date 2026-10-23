import Foundation

/// What the workspace can do with one speaker's voice.
enum SpeakerVoiceState: String, Equatable {
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

/// 保存录音的说话人特征并建议姓名，在用户确认后创建或更新声音档案。
@MainActor
final class SpeakerVoiceProfileService: ObservableObject {
    let store: VoiceProfileStore
    private let historyService: HistoryService

    init(
        store: VoiceProfileStore,
        historyService: HistoryService
    ) {
        self.store = store
        self.historyService = historyService
        historyService.onRecordsDeleted = { [weak store] ids in
            store?.removeEmbeddings(forRecordIDs: Set(ids))
        }
        historyService.onSpeakerNamesWillChange = { [weak store] record in
            guard let transcript = record.speakerTranscript else { return }
            try store?.rememberConfirmedLinks(recordID: record.id, transcript: transcript, names: record.speakerNames)
        }
        for (id, stored) in store.recordingEmbeddings where stored.transcriptVersion == nil {
            guard let record = historyService.record(withID: id), let transcript = record.speakerTranscript else { continue }
            // Failed migrations remain unstamped and cannot be used for learning.
            try? store.rememberConfirmedLinks(recordID: id, transcript: transcript, names: record.speakerNames)
        }
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
        let speakerIDs = Set(transcript.speakerIDs)
        store.storeEmbeddings(
            embeddings.filter { speakerIDs.contains($0.key) },
            model: model,
            forRecordID: recordID,
            revision: transcript.revision,
            version: transcript.automationVersion
        )
        suggestNames(inRecordID: recordID)
    }

    /// Moves embeddings along when turns were moved or speakers merged; an
    /// undo passes the embeddings that belonged to the transcript it restores.
    func transcriptCorrected(
        recordID: UUID,
        from old: SpeakerTranscript,
        to new: SpeakerTranscript,
        restoring saved: RecordingSpeakerEmbeddings? = nil
    ) {
        store.transcriptCorrected(recordID: recordID, from: old, to: new, restoring: saved)
    }

    /// The recording's stored embeddings as they are now, for undoing a correction.
    func storedVoices(ofRecordID recordID: UUID) -> RecordingSpeakerEmbeddings? {
        store.recordingEmbeddings[recordID]
    }

    /// Drops embeddings of recordings that were deleted.
    func removeEmbeddingsOfDeletedRecordings() {
        let kept = Set(store.storedRecordIDs.filter { historyService.record(withID: $0) != nil })
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
    /// that no speaker of it uses yet and the user did not reject for them.
    /// Names the user gave stay untouched.
    private func suggestNames(inRecordID recordID: UUID) {
        guard let record = historyService.record(withID: recordID),
              let transcript = record.speakerTranscript,
              store.hasCurrentEmbeddings(recordID: recordID, transcript: transcript) else { return }
        let names = record.speakerNames
        let embeddings = store.embeddings(forRecordID: recordID, revision: transcript.revision)
            .filter { names?.displayName(for: $0.key) == nil }
        let usedProfiles = Set(transcript.speakerIDs.compactMap { names?.profileID(for: $0) })
        let matches = VoiceProfileMatching.matches(
            speakers: embeddings,
            embeddingModel: store.embeddingModel(forRecordID: recordID, revision: transcript.revision),
            speakingTime: transcript.speakingTime(of:),
            profiles: store.profiles.filter { !usedProfiles.contains($0.id) },
            rejected: { names?.rejectedProfileIDs(for: $0) ?? [] }
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
        guard let record = historyService.record(withID: recordID), let transcript = record.speakerTranscript,
              let state = automationStates(record: record, transcript: transcript)[speakerID]?.voice_state else { return .none }
        return SpeakerVoiceState(rawValue: state) ?? .none
    }

    /// A named speaker's voice in this recording. Only embeddings of the
    /// current model count, so an older recording can't put an outdated
    /// voice into a profile.
    private func voice(
        of speakerID: String,
        inRecordID recordID: UUID
    ) -> (name: String, profileID: UUID?, embedding: [Float], model: String, seconds: TimeInterval)? {
        guard let record = historyService.record(withID: recordID),
              let transcript = record.speakerTranscript,
              store.hasCurrentEmbeddings(recordID: recordID, transcript: transcript),
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
        let candidates = store.profiles.filter {
            SpeakerTranscriptPresentation.nameKey($0.name) == SpeakerTranscriptPresentation.nameKey(voice.name)
        }
        guard candidates.count <= 1 else { return }
        learnFromWorkspace(speakerID, recordID: recordID, voice: voice,
                           profileID: candidates.first?.id)
    }

    /// Confirms a recognized name; the profile learns from this recording.
    func confirm(_ speakerID: String, inRecordID recordID: UUID) {
        guard state(of: speakerID, inRecordID: recordID) == .suggestion,
              let voice = voice(of: speakerID, inRecordID: recordID),
              let profileID = voice.profileID else { return }
        learnFromWorkspace(speakerID, recordID: recordID, voice: voice, profileID: profileID)
    }

    private func learnFromWorkspace(
        _ speakerID: String, recordID: UUID,
        voice: (name: String, profileID: UUID?, embedding: [Float], model: String, seconds: TimeInterval),
        profileID: UUID?
    ) {
        guard let transcript = historyService.record(withID: recordID)?.speakerTranscript else { return }
        do {
            let result = try store.learnOnce(
                recordID: recordID, revision: transcript.revision, speakerID: speakerID,
                version: transcript.automationVersion, profileID: profileID,
                name: voice.name, embedding: voice.embedding, model: voice.model, seconds: voice.seconds,
                workspaceAssignment: true
            )
            try historyService.setSpeakerNamePersisted(
                voice.name, for: speakerID, profileID: result.profile.id, inRecordID: recordID
            )
            suggestNamesInStoredRecordings()
        } catch {
            // Leave the operation available for retry; never confirm a name if
            // saving the voice failed. API callers receive the explicit error.
            return
        }
    }

    /// Rejects a recognized name; the profile stays as it is and is not
    /// suggested for this speaker again.
    func reject(_ speakerID: String, inRecordID recordID: UUID) {
        guard state(of: speakerID, inRecordID: recordID) == .suggestion else { return }
        historyService.rejectSpeakerSuggestion(for: speakerID, inRecordID: recordID)
    }

    /// Replaces the profile's voice with this recording's, when the old one
    /// came from poor audio, the wrong person, or an older model.
    func relearn(_ speakerID: String, inRecordID recordID: UUID) {
        guard [.linked, .outdated].contains(state(of: speakerID, inRecordID: recordID)),
              let voice = voice(of: speakerID, inRecordID: recordID),
              let profileID = voice.profileID,
              let transcript = historyService.record(withID: recordID)?.speakerTranscript else { return }
        do {
            _ = try store.learnOnce(
                recordID: recordID, revision: transcript.revision, speakerID: speakerID,
                version: transcript.automationVersion, profileID: profileID, name: voice.name,
                embedding: voice.embedding, model: voice.model, seconds: voice.seconds,
                workspaceAssignment: true, replacing: true
            )
            suggestNamesInStoredRecordings()
        } catch { return }
    }

    // MARK: - Scripted speaker corrections

    struct OperationError: Error {
        let status: Int
        let code: String
        let message: String
        var profileIDs: [UUID]? = nil
    }

    struct AutomationState: Encodable {
        let history_id: UUID
        let transcript_revision: UUID
        let transcript_version: String
        let speaker_id: String
        let name: String?
        let suggested_name: String?
        let profile_id: UUID?
        let voice_state: String
        var already_learned = false
    }

    /// One decoded transcript and one pass over its segments for the whole record.
    /// History calls this once, not once (and several store fetches) per speaker.
    func automationStates(record: TranscriptionRecord, transcript: SpeakerTranscript) -> [String: AutomationState] {
        let names = record.speakerNames
        let version = transcript.automationVersion
        let stored = store.recordingEmbeddings[record.id]
        let current = stored?.transcriptRevision == transcript.revision && stored?.transcriptVersion == version
        let embeddings = current ? (stored?.embeddings ?? [:]) : [:]
        let model = current ? stored?.embeddingModel : nil
        let profiles = Dictionary(uniqueKeysWithValues: store.profiles.map { ($0.id, $0) })
        let nameCounts = Dictionary(grouping: store.profiles, by: { SpeakerTranscriptPresentation.nameKey($0.name) }).mapValues(\.count)
        let entries = Dictionary((names?.entries ?? []).map { ($0.speakerID, $0) }, uniquingKeysWith: { _, last in last })
        var seconds: [String: TimeInterval] = [:]
        for segment in transcript.segments {
            if let id = segment.speakerID { seconds[id, default: 0] += max(0, segment.end - segment.start) }
        }
        return Dictionary(uniqueKeysWithValues: seconds.keys.map { speakerID in
            let entry = entries[speakerID]
            let suggestion = entry?.isSuggestion == true
            let profile = entry?.profileID.flatMap { profiles[$0] }
            let hasVoice = entry != nil && model != nil && model == store.currentEmbeddingModel && embeddings[speakerID] != nil
            let state: SpeakerVoiceState
            if let profile {
                state = suggestion ? .suggestion : (store.isOutdated(profile) && hasVoice ? .outdated : .linked)
            } else {
                let ambiguousName = entry.map { nameCounts[SpeakerTranscriptPresentation.nameKey($0.displayName), default: 0] > 1 } ?? false
                state = hasVoice && !ambiguousName && seconds[speakerID, default: 0] >= VoiceProfileMatching.minimumSpeechSeconds ? .canEnroll : .none
            }
            return (speakerID, AutomationState(
                history_id: record.id, transcript_revision: transcript.revision, transcript_version: version,
                speaker_id: speakerID, name: suggestion ? nil : entry?.displayName,
                suggested_name: suggestion ? entry?.displayName : nil, profile_id: profile?.id, voice_state: state.rawValue
            ))
        })
    }

    func automationState(recordID: UUID, speakerID: String, alreadyLearned: Bool = false) -> AutomationState? {
        guard let record = historyService.record(withID: recordID), let transcript = record.speakerTranscript,
              var state = automationStates(record: record, transcript: transcript)[speakerID] else { return nil }
        state.already_learned = alreadyLearned
        return state
    }

    private func automationResult(recordID: UUID, speakerID: String, alreadyLearned: Bool = false) throws -> AutomationState {
        guard let state = automationState(recordID: recordID, speakerID: speakerID, alreadyLearned: alreadyLearned) else {
            throw OperationError(status: 500, code: "history_unavailable", message: "Could not read the saved speaker")
        }
        return state
    }

    private func automationRecord(recordID: UUID, revision: UUID, version: String, speakerID: String) throws -> TranscriptionRecord {
        guard let record = historyService.record(withID: recordID) else {
            throw OperationError(status: 404, code: "history_not_found", message: "History entry not found")
        }
        guard record.speakerTranscriptState == .ready, let transcript = record.speakerTranscript else {
            throw OperationError(status: 409, code: "speakers_not_ready", message: "Speaker detection is not ready")
        }
        guard transcript.revision == revision, transcript.automationVersion == version else {
            throw OperationError(status: 409, code: "stale_transcript", message: "Read the current speaker transcript before retrying")
        }
        guard transcript.speakerIDs.contains(speakerID) else {
            throw OperationError(status: 404, code: "speaker_not_found", message: "Speaker does not belong to this transcript")
        }
        return record
    }

    func nameFromAutomation(recordID: UUID, revision: UUID, version: String, speakerID: String, name: String) throws -> AutomationState {
        let record = try automationRecord(recordID: recordID, revision: revision, version: version, speakerID: speakerID)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= SpeakerNameTable.maximumNameLength,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw OperationError(status: 400, code: "invalid_name", message: "Name must contain 1 to 100 characters without control characters")
        }
        let names = record.speakerNames
        let keepsLink = names?.isSuggestion(for: speakerID) != true
            && names?.displayName(for: speakerID).map(SpeakerTranscriptPresentation.nameKey) == SpeakerTranscriptPresentation.nameKey(trimmed)
        try historyService.setSpeakerNamePersisted(
            trimmed, for: speakerID, profileID: keepsLink ? names?.profileID(for: speakerID) : nil, inRecordID: recordID
        )
        return try automationResult(recordID: recordID, speakerID: speakerID)
    }

    func learnFromAutomation(
        recordID: UUID, revision: UUID, version: String, speakerID: String,
        profileID: UUID?, confirming: Bool, createProfile: Bool = false
    ) throws -> AutomationState {
        let record = try automationRecord(recordID: recordID, revision: revision, version: version, speakerID: speakerID)
        let names = record.speakerNames
        let linkedID = names?.profileID(for: speakerID)
        let suggestion = names?.isSuggestion(for: speakerID) == true
        guard let transcript = record.speakerTranscript else {
            throw OperationError(status: 409, code: "speakers_not_ready", message: "Speaker detection is not ready")
        }
        try store.rememberConfirmedLinks(recordID: recordID, transcript: transcript, names: names)
        let hasCurrent = store.hasCurrentEmbeddings(recordID: recordID, transcript: transcript)
        let learnedIDs = hasCurrent ? store.learnedProfiles(recordID: recordID, revision: revision, speakerID: speakerID) : []
        if confirming {
            guard let profileID, linkedID == profileID,
                  suggestion || learnedIDs.contains(profileID) || (!suggestion && store.profile(withID: profileID) != nil) else {
                throw OperationError(status: 409, code: "suggestion_changed", message: "The speaker no longer has this profile suggestion")
            }
        } else if suggestion {
            throw OperationError(status: 409, code: "confirmation_required", message: "Confirm the suggestion or set a name before enrollment")
        }
        guard let name = names?.displayName(for: speakerID) else {
            throw OperationError(status: 422, code: "name_required", message: "Name this speaker before enrollment")
        }
        let nameKey = SpeakerTranscriptPresentation.nameKey(name)
        let namedProfiles = store.profiles.filter { SpeakerTranscriptPresentation.nameKey($0.name) == nameKey }
        var targetID = profileID
        if targetID == nil {
            let learnedNamed = namedProfiles.filter { learnedIDs.contains($0.id) }
            if let linkedID, !suggestion, store.profile(withID: linkedID) != nil {
                targetID = linkedID
            } else if learnedNamed.count == 1 {
                targetID = learnedNamed[0].id
            } else if !namedProfiles.isEmpty && (!createProfile || learnedNamed.count > 1) {
                throw OperationError(status: 409, code: "profile_name_exists", message: "Select an existing profile_id or explicitly create a different person's profile", profileIDs: namedProfiles.map(\.id))
            } else if !learnedIDs.isEmpty {
                throw OperationError(status: 409, code: "sample_already_used", message: "This sample was already learned; select its profile or correct it in the app")
            }
        }
        if let targetID, let profile = store.profile(withID: targetID), SpeakerTranscriptPresentation.nameKey(profile.name) != nameKey {
            throw OperationError(status: 409, code: "profile_name_conflict", message: "The speaker name does not match the requested profile")
        }
        // If retained embeddings are gone, an existing confirmed link remains a
        // no-op. A mismatched version is different: never trust its label mapping.
        if store.recordingEmbeddings[recordID] == nil, let targetID, linkedID == targetID, !suggestion,
           store.profile(withID: targetID) != nil {
            return try automationResult(recordID: recordID, speakerID: speakerID, alreadyLearned: true)
        }
        if store.recordingEmbeddings[recordID] == nil {
            throw OperationError(status: 422, code: "voice_unavailable", message: "No local voice samples are available")
        }
        guard hasCurrent else {
            throw OperationError(status: 409, code: "stale_voice_samples", message: "Local voice samples do not match this transcript; run speaker detection again")
        }
        if store.hasLearning(recordID: recordID, revision: revision, speakerID: speakerID),
           targetID.map({ !learnedIDs.contains($0) }) ?? true {
            throw OperationError(status: 409, code: "sample_already_used", message: "This sample was already partly or fully learned; correct its profile explicitly in the app")
        }
        let result: (profile: VoiceProfile, alreadyLearned: Bool)
        do {
            if let targetID, learnedIDs.contains(targetID) {
                guard let profile = store.profile(withID: targetID) else { throw VoiceProfileStore.LearningError.missingProfile }
                result = (profile, true)
            } else {
                guard let voice = voice(of: speakerID, inRecordID: recordID), voice.seconds >= VoiceProfileMatching.minimumSpeechSeconds else {
                    throw OperationError(status: 422, code: "voice_unavailable", message: "Learning requires at least 20 seconds of speech and current local speaker embeddings")
                }
                result = try store.learnOnce(
                    recordID: recordID, revision: revision, speakerID: speakerID, version: version, profileID: targetID,
                    name: name, embedding: voice.embedding, model: voice.model, seconds: voice.seconds
                )
            }
        } catch let error as VoiceProfileStore.LearningError {
            switch error {
            case .missingProfile:
                throw OperationError(status: 409, code: "profile_unavailable", message: "The requested or previously learned profile no longer exists")
            case .conflictingSample, .partiallyLearned:
                throw OperationError(status: 409, code: "sample_already_used", message: "Part of this voice sample was already learned; use explicit relearning in the app")
            case .staleEmbeddings:
                throw OperationError(status: 409, code: "stale_voice_samples", message: "Voice samples no longer match the transcript")
            case .incompatibleModel:
                throw OperationError(status: 409, code: "profile_model_changed", message: "Relearn this profile in the app before using it with the current model")
            case .invalidEmbedding:
                throw OperationError(status: 422, code: "invalid_embedding", message: "The stored voice sample is not usable")
            }
        }
        try historyService.setSpeakerNamePersisted(name, for: speakerID, profileID: result.profile.id, inRecordID: recordID)
        suggestNamesInStoredRecordings()
        return try automationResult(recordID: recordID, speakerID: speakerID, alreadyLearned: result.alreadyLearned)
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
        // Names the profile only suggested are guesses without it; confirmed names stay.
        for record in historyService.recordsWithSpeakerNames() {
            for entry in record.speakerNames?.entries ?? []
            where entry.profileID == profileID && entry.isSuggestion == true {
                historyService.setSpeakerName("", for: entry.speakerID, inRecordID: record.id)
            }
        }
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
