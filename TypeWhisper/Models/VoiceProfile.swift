import Foundation

/// A named voice that TypeWhisper recognizes in later recordings.
///
/// Holds the duration-weighted mean of the diarizer's speaker embeddings and
/// no audio. Voice profiles are biometric data: they stay on this device and
/// are never part of History, sync, backups, or exports.
struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var embedding: [Float]
    /// The model that produced `embedding`. Nil for profiles learned before
    /// the model was recorded; those never match.
    var embeddingModel: String?
    /// Speech the embedding was learned from, in seconds.
    var enrolledSeconds: TimeInterval
    let createdAt: Date
    var updatedAt: Date
}

/// A recording where a voice profile's person speaks, for the profile's page.
struct VoiceProfileAppearance: Identifiable, Equatable {
    let recordID: UUID
    let title: String
    let date: Date
    /// True while the name there is only recognized, not confirmed.
    let isSuggestion: Bool
    let turns: [SpeakerTranscriptTurn]

    var id: UUID { recordID }
}

/// Speaker embeddings of one recording's current speaker transcript, kept on
/// the device so a named speaker can still become a voice profile.
struct RecordingSpeakerEmbeddings: Codable, Equatable, Sendable {
    let transcriptRevision: UUID
    /// The model that produced `embeddings`; nil when stored before it was recorded.
    var embeddingModel: String?
    var embeddings: [String: [Float]]
}

/// Matching rules for voice profiles.
///
/// Values come from a cross-meeting benchmark of the diarizer's embeddings:
/// 16 AMI participants recorded in four meetings each and three German
/// podcast episodes, profiles from one meeting matched against the others.
/// With a meeting's worth of speech the right person scored at least 0.74,
/// even on another microphone, and other people at most 0.66; no one got a
/// wrong name above 0.63. 0.80 missed many speakers with little speech or a
/// different microphone that 0.70 recognizes. A cluster that merged two
/// voices is the main risk for a wrong name, so names stay suggestions.
enum VoiceProfileMatching {
    static let recognitionThreshold: Float = 0.70
    static let minimumLead: Float = 0.10
    /// Shorter speech gives unreliable embeddings, for matching and enrolling.
    static let minimumSpeechSeconds: TimeInterval = 20

    struct Match: Equatable, Sendable {
        let profileID: UUID
        let similarity: Float
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Assigns each profile to at most one speaker and each speaker to at most
    /// one profile, best pairs first. A pair counts only above the threshold,
    /// with enough speech, and when the speaker's best profile clearly leads
    /// its second best. Only profiles of the speakers' embedding model count:
    /// another model's vectors aren't comparable, even with the same length.
    static func matches(
        speakers: [String: [Float]],
        embeddingModel: String?,
        speakingTime: (String) -> TimeInterval,
        profiles: [VoiceProfile]
    ) -> [String: Match] {
        guard let embeddingModel else { return [:] }
        let profiles = profiles.filter { $0.embeddingModel == embeddingModel }
        var candidates: [(speakerID: String, match: Match)] = []
        for (speakerID, embedding) in speakers where speakingTime(speakerID) >= minimumSpeechSeconds {
            let scores = profiles
                .map { Match(profileID: $0.id, similarity: cosineSimilarity(embedding, $0.embedding)) }
                .sorted { $0.similarity > $1.similarity }
            guard let best = scores.first, best.similarity >= recognitionThreshold else { continue }
            if scores.count > 1, best.similarity - scores[1].similarity < minimumLead { continue }
            candidates.append((speakerID, best))
        }
        var result: [String: Match] = [:]
        var usedProfiles = Set<UUID>()
        for candidate in candidates.sorted(by: { $0.match.similarity > $1.match.similarity })
        where !usedProfiles.contains(candidate.match.profileID) {
            result[candidate.speakerID] = candidate.match
            usedProfiles.insert(candidate.match.profileID)
        }
        return result
    }

    /// Duration-weighted mean of two embeddings.
    static func mean(_ a: [Float], weight weightA: TimeInterval, _ b: [Float], weight weightB: TimeInterval) -> [Float] {
        guard a.count == b.count, weightA + weightB > 0 else { return weightB > weightA ? b : a }
        let total = Float(weightA + weightB)
        return zip(a, b).map { ($0 * Float(weightA) + $1 * Float(weightB)) / total }
    }

    /// Embeddings for a corrected transcript of the same revision. A speaker
    /// keeps the embeddings of the old speakers whose speech mostly went to
    /// them, weighted by that speech: a merged speaker gets the mean of both,
    /// a speaker created for a moved or split-off turn gets none. Speech is
    /// matched by time, since splitting a turn adds a segment.
    static func correctedEmbeddings(
        _ embeddings: [String: [Float]],
        from old: SpeakerTranscript,
        to new: SpeakerTranscript
    ) -> [String: [Float]] {
        var shares: [String: [String: TimeInterval]] = [:]
        var first = 0
        for before in old.segments {
            guard let oldID = before.speakerID, before.end > before.start else { continue }
            while first < new.segments.count, new.segments[first].end <= before.start { first += 1 }
            var index = first
            while index < new.segments.count, new.segments[index].start < before.end {
                let after = new.segments[index]
                let overlap = min(before.end, after.end) - max(before.start, after.start)
                if let newID = after.speakerID, overlap > 0 {
                    shares[oldID, default: [:]][newID, default: 0] += overlap
                }
                index += 1
            }
        }
        var sums: [String: (embedding: [Float], weight: TimeInterval)] = [:]
        for (oldID, targets) in shares {
            guard let embedding = embeddings[oldID] else { continue }
            let total = targets.values.reduce(0, +)
            guard let target = targets.max(by: { $0.value < $1.value }), target.value > total / 2 else { continue }
            let newID = target.key
            let weight = old.speakingTime(of: oldID)
            if let sum = sums[newID] {
                sums[newID] = (mean(sum.embedding, weight: sum.weight, embedding, weight: weight), sum.weight + weight)
            } else {
                sums[newID] = (embedding, weight)
            }
        }
        return sums.mapValues(\.embedding)
    }
}
