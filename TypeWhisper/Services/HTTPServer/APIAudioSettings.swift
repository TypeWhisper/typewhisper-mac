import Foundation

/// Request and response shapes for `GET`/`PATCH /v1/settings/audio`.
/// TypeWhisper for Windows serves the same contract, so field names and
/// error cases must stay in step with it.
enum APIAudioSettings {
    struct Device: Encodable, Equatable {
        let id: String
        let name: String
    }

    struct InputDevice: Encodable, Equatable {
        let id: String
        let name: String
        let isSystemDefault: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case isSystemDefault = "is_system_default"
        }
    }

    struct State: Encodable, Equatable {
        let inputDevices: [InputDevice]
        let inputPriority: [Device]
        let activeInput: Device?
        let audioDuckingEnabled: Bool
        let audioDuckingLevel: Double
        let pauseMediaDuringRecording: Bool
        let soundFeedbackEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case inputDevices = "input_devices"
            case inputPriority = "input_priority"
            case activeInput = "active_input"
            case audioDuckingEnabled = "audio_ducking_enabled"
            case audioDuckingLevel = "audio_ducking_level"
            case pauseMediaDuringRecording = "pause_media_during_recording"
            case soundFeedbackEnabled = "sound_feedback_enabled"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(inputDevices, forKey: .inputDevices)
            try container.encode(inputPriority, forKey: .inputPriority)
            // The contract always carries the key, with null when no input exists.
            if let activeInput {
                try container.encode(activeInput, forKey: .activeInput)
            } else {
                try container.encodeNil(forKey: .activeInput)
            }
            try container.encode(audioDuckingEnabled, forKey: .audioDuckingEnabled)
            try container.encode(audioDuckingLevel, forKey: .audioDuckingLevel)
            try container.encode(pauseMediaDuringRecording, forKey: .pauseMediaDuringRecording)
            try container.encode(soundFeedbackEnabled, forKey: .soundFeedbackEnabled)
        }
    }

    struct Patch: Equatable {
        var inputPriority: [AudioInputDevicePriorityItem]?
        var audioDuckingEnabled: Bool?
        var audioDuckingLevel: Double?
        var pauseMediaDuringRecording: Bool?
        var soundFeedbackEnabled: Bool?
    }

    struct PatchError: Error, Equatable {
        let message: String
    }

    static let writableFields = [
        "input_priority",
        "audio_ducking_enabled",
        "audio_ducking_level",
        "pause_media_during_recording",
        "sound_feedback_enabled",
    ]
    static let readOnlyFields: Set<String> = ["input_devices", "active_input"]
    /// The recording path clamps the level to this range. The settings slider
    /// offers 0 to 0.5, but restoring must accept anything the app stored.
    static let audioDuckingLevelRange: ClosedRange<Double> = 0...1

    static func parsePatch(_ body: Data) throws(PatchError) -> Patch {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw PatchError(message: "Request body must be a JSON object")
        }

        for key in object.keys.sorted() where !writableFields.contains(key) {
            if readOnlyFields.contains(key) {
                throw PatchError(message: "'\(key)' is read-only")
            }
            throw PatchError(
                message: "Unknown field '\(key)'. TypeWhisper for macOS accepts: \(writableFields.joined(separator: ", "))"
            )
        }

        var patch = Patch()
        if let value = object["input_priority"] {
            patch.inputPriority = try parseInputPriority(value)
        }
        if let value = object["audio_ducking_enabled"] {
            patch.audioDuckingEnabled = try boolean(value, field: "audio_ducking_enabled")
        }
        if let value = object["audio_ducking_level"] {
            guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue.isFinite,
                  audioDuckingLevelRange.contains(number.doubleValue) else {
                throw PatchError(message: "'audio_ducking_level' must be a number from 0 to 1")
            }
            patch.audioDuckingLevel = number.doubleValue
        }
        if let value = object["pause_media_during_recording"] {
            patch.pauseMediaDuringRecording = try boolean(value, field: "pause_media_during_recording")
        }
        if let value = object["sound_feedback_enabled"] {
            patch.soundFeedbackEnabled = try boolean(value, field: "sound_feedback_enabled")
        }
        return patch
    }

    /// A PATCH may not land while the microphone is in use or a dictation is
    /// still being processed; switching inputs then would split a recording.
    @MainActor
    static func isAudioInUse(dictationState: DictationViewModel.State, recorderState: AudioRecorderViewModel.RecorderState) -> Bool {
        switch dictationState {
        case .idle, .error:
            return recorderState != .idle
        case .recording, .processing, .inserting, .promptSelection, .promptProcessing:
            return true
        }
    }

    @MainActor
    static func state(audioDeviceService: AudioDeviceService, dictationViewModel: DictationViewModel) -> State {
        let systemDefaultUID = audioDeviceService.systemDefaultInputDeviceUID
        return State(
            inputDevices: audioDeviceService.inputDevices.map {
                InputDevice(id: $0.uid, name: $0.name, isSystemDefault: $0.uid == systemDefaultUID)
            },
            inputPriority: audioDeviceService.inputDevicePriorityList.map { Device(id: $0.uid, name: $0.name) },
            activeInput: audioDeviceService.activeRecordingInput().map { Device(id: $0.uid, name: $0.name) },
            audioDuckingEnabled: dictationViewModel.audioDuckingEnabled,
            audioDuckingLevel: dictationViewModel.audioDuckingLevel,
            pauseMediaDuringRecording: dictationViewModel.mediaPauseEnabled,
            soundFeedbackEnabled: dictationViewModel.soundFeedbackEnabled
        )
    }

    private static func parseInputPriority(_ value: Any) throws(PatchError) -> [AudioInputDevicePriorityItem] {
        guard let entries = value as? [Any] else {
            throw PatchError(message: "'input_priority' must be an array of {\"id\", \"name\"} objects")
        }

        var items: [AudioInputDevicePriorityItem] = []
        var seenIDs = Set<String>()
        for (index, entry) in entries.enumerated() {
            guard let fields = entry as? [String: Any] else {
                throw PatchError(message: "input_priority[\(index)] must be an object with \"id\" and optional \"name\"")
            }
            if let unknownKey = fields.keys.sorted().first(where: { $0 != "id" && $0 != "name" }) {
                throw PatchError(message: "Unknown field '\(unknownKey)' in input_priority[\(index)]")
            }
            guard let rawID = fields["id"] as? String else {
                throw PatchError(message: "input_priority[\(index)].id must be a device ID string")
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw PatchError(message: "input_priority[\(index)].id must not be empty")
            }
            guard seenIDs.insert(id).inserted else {
                throw PatchError(message: "input_priority lists '\(id)' more than once")
            }

            let name: String
            switch fields["name"] {
            case nil:
                name = id
            case let value as String:
                name = value
            default:
                throw PatchError(message: "input_priority[\(index)].name must be a string")
            }
            // Connected devices get their current name when the list is saved.
            items.append(AudioInputDevicePriorityItem(uid: id, name: name))
        }
        return items
    }

    private static func boolean(_ value: Any, field: String) throws(PatchError) -> Bool {
        guard let number = value as? NSNumber, isBoolean(number) else {
            throw PatchError(message: "'\(field)' must be true or false")
        }
        return number.boolValue
    }

    /// JSONSerialization returns numbers and booleans as NSNumber, and `is Bool`
    /// accepts 0 and 1 as well, so check the underlying CoreFoundation type.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
