import Foundation

/// Local-only writes: remote pairing does not authorize biometric enrollment.
enum APISpeakerProfiles {
    enum Action: String {
        case name, enroll, confirm
    }

    static func register(on router: APIRouter, service: SpeakerVoiceProfileService) {
        for action in [Action.name, .enroll, .confirm] {
            router.register(
                action == .name ? "PUT" : "POST", "/v1/history/speakers/\(action.rawValue)", requiresToken: true
            ) { request in
                await respond(request, action: action, service: service)
            }
        }
    }

    private struct Mutation: Decodable {
        let history_id: UUID
        let transcript_revision: UUID
        let transcript_version: String
        let speaker_id: String
        let name: String?
        let profile_id: UUID?
        let create_profile: Bool?
    }

    @MainActor
    static func respond(_ request: HTTPRequest, action: Action, service: SpeakerVoiceProfileService) -> HTTPResponse {
        guard request.body.count <= 16_384 else {
            return .error(status: 413, message: "Speaker request exceeds 16 KiB")
        }
        let mutation: Mutation
        do {
            var allowed: Set<String> = ["history_id", "transcript_revision", "transcript_version", "speaker_id",
                                       action == .name ? "name" : "profile_id"]
            if action == .enroll { allowed.insert("create_profile") }
            guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  Set(object.keys).isSubset(of: allowed) else {
                return .error(status: 400, message: "Expected a JSON object with only documented fields")
            }
            mutation = try JSONDecoder().decode(Mutation.self, from: request.body)
            guard !mutation.speaker_id.isEmpty, !mutation.transcript_version.isEmpty,
                  !(mutation.create_profile == true && mutation.profile_id != nil),
                  action != .name || mutation.name != nil,
                  action != .confirm || mutation.profile_id != nil else {
                return .error(status: 400, message: "Missing required speaker fields or conflicting profile options")
            }
        } catch {
            return .error(status: 400, message: "Invalid speaker request; require history_id and transcript_revision UUIDs, transcript_version and speaker_id")
        }
        do {
            if action == .name {
                return .json(try service.nameFromAutomation(
                    recordID: mutation.history_id, revision: mutation.transcript_revision, version: mutation.transcript_version,
                    speakerID: mutation.speaker_id, name: mutation.name!
                ))
            }
            return .json(try service.learnFromAutomation(
                recordID: mutation.history_id, revision: mutation.transcript_revision, version: mutation.transcript_version,
                speakerID: mutation.speaker_id, profileID: mutation.profile_id, confirming: action == .confirm,
                createProfile: mutation.create_profile ?? false
            ))
        } catch let error as SpeakerVoiceProfileService.OperationError {
            struct ErrorBody: Encodable {
                struct Detail: Encodable {
                    let code: String
                    let message: String
                    let profile_ids: [UUID]?
                }
                let error: Detail
            }
            return .json(ErrorBody(error: .init(code: error.code, message: error.message, profile_ids: error.profileIDs)), status: error.status)
        } catch {
            return .error(status: 500, message: "Could not persist speaker changes; retry the same request", code: "speaker_save_failed")
        }
    }
}
