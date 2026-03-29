import AppKit
import UniformTypeIdentifiers

enum SoundChoice: Hashable, Sendable {
    case bundled(String)
    case system(String)
    case custom(String)
    case none

    var storageKey: String {
        switch self {
        case .bundled(let name): return "bundled:\(name)"
        case .system(let name): return "system:\(name)"
        case .custom(let name): return "custom:\(name)"
        case .none: return "none"
        }
    }

    init(storageKey: String) {
        if storageKey == "none" {
            self = .none
        } else if storageKey.hasPrefix("bundled:") {
            self = .bundled(String(storageKey.dropFirst(8)))
        } else if storageKey.hasPrefix("system:") {
            self = .system(String(storageKey.dropFirst(7)))
        } else if storageKey.hasPrefix("custom:") {
            self = .custom(String(storageKey.dropFirst(7)))
        } else {
            self = .none
        }
    }

    var displayName: String {
        switch self {
        case .bundled(let name):
            return Self.bundledSounds.first(where: { $0.name == name })?.displayName ?? name
        case .system(let name):
            return name
        case .custom(let name):
            return name
        case .none:
            return String(localized: "None")
        }
    }

    static let systemSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    static let bundledSounds: [(name: String, displayName: String)] = [
        ("recording_start", String(localized: "Recording Start")),
        ("transcription_success", String(localized: "Transcription Success")),
        ("error", String(localized: "Error"))
    ]

    static var customSoundsDirectory: URL {
        AppConstants.appSupportDirectory.appendingPathComponent("Sounds", isDirectory: true)
    }

    static func installedCustomSounds() -> [String] {
        let dir = customSoundsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let audioExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
        return contents
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.lastPathComponent }
            .sorted()
    }

    static let allowedContentTypes: [UTType] = [
        .wav, .aiff, .mp3, .mpeg4Audio,
        UTType(filenameExtension: "caf") ?? .audio
    ]
}

enum SoundEvent: CaseIterable {
    case recordingStarted
    case transcriptionSuccess
    case error

    var fileName: String {
        switch self {
        case .recordingStarted: return "recording_start"
        case .transcriptionSuccess: return "transcription_success"
        case .error: return "error"
        }
    }

    var defaultChoice: SoundChoice {
        .bundled(fileName)
    }

    var userDefaultsKey: String {
        switch self {
        case .recordingStarted: return UserDefaultsKeys.soundRecordingStarted
        case .transcriptionSuccess: return UserDefaultsKeys.soundTranscriptionSuccess
        case .error: return UserDefaultsKeys.soundError
        }
    }

    var displayName: String {
        switch self {
        case .recordingStarted: return String(localized: "Recording started")
        case .transcriptionSuccess: return String(localized: "Transcription success")
        case .error: return String(localized: "Error")
        }
    }
}

@MainActor
class SoundService {
    private var sounds: [SoundEvent: NSSound] = [:]
    private var choices: [SoundEvent: SoundChoice] = [:]
    private var resolvedSounds: [SoundChoice: NSSound] = [:]
    private var previewSound: NSSound?

    init() {
        preloadSounds()
        loadChoices()
    }

    func play(_ event: SoundEvent, enabled: Bool) {
        guard enabled else { return }
        let choice = choices[event] ?? event.defaultChoice
        guard let sound = sound(for: choice) else { return }
        sound.stop()
        sound.play()
    }

    func choice(for event: SoundEvent) -> SoundChoice {
        choices[event] ?? event.defaultChoice
    }

    func updateChoice(for event: SoundEvent, choice: SoundChoice) {
        choices[event] = choice
        UserDefaults.standard.set(choice.storageKey, forKey: event.userDefaultsKey)
    }

    func preview(_ choice: SoundChoice) {
        previewSound?.stop()
        guard let sound = sound(for: choice) else { return }
        previewSound = sound
        sound.play()
    }

    func importCustomSound(from sourceURL: URL) throws -> String {
        let dir = SoundChoice.customSoundsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = sourceURL.lastPathComponent
        let destination = dir.appendingPathComponent(filename)
        resolvedSounds[.custom(filename)] = nil
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return filename
    }

    func deleteCustomSound(_ filename: String) {
        let path = SoundChoice.customSoundsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: path)
        resolvedSounds[.custom(filename)] = nil
        for event in SoundEvent.allCases {
            if choices[event] == .custom(filename) {
                updateChoice(for: event, choice: event.defaultChoice)
            }
        }
    }

    func sound(for choice: SoundChoice) -> NSSound? {
        if let sound = resolvedSounds[choice] {
            return sound
        }

        let sound: NSSound?
        switch choice {
        case .bundled(let name):
            if let event = SoundEvent.allCases.first(where: { $0.fileName == name }) {
                sound = sounds[event]
            } else {
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
                sound = NSSound(contentsOf: url, byReference: true)
            }
        case .system(let name):
            sound = NSSound(named: NSSound.Name(name))
        case .custom(let filename):
            let url = SoundChoice.customSoundsDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            sound = NSSound(contentsOf: url, byReference: true)
        case .none:
            return nil
        }

        guard let sound else { return nil }
        resolvedSounds[choice] = sound
        return sound
    }

    private func preloadSounds() {
        for event in SoundEvent.allCases {
            if let url = Bundle.main.url(forResource: event.fileName, withExtension: "wav") {
                sounds[event] = NSSound(contentsOf: url, byReference: true)
            }
        }
    }

    private func loadChoices() {
        for event in SoundEvent.allCases {
            if let key = UserDefaults.standard.string(forKey: event.userDefaultsKey) {
                choices[event] = SoundChoice(storageKey: key)
            }
        }
    }
}
