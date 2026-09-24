import AppKit
import AVFoundation
import CoreAudio
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

/// The part of `AVAudioPlayer` used for sound cues, so tests can observe player creation.
protocol SoundCuePlayback: AnyObject {
    var duration: TimeInterval { get }
    @discardableResult
    func prepareToPlay() -> Bool
    @discardableResult
    func play() -> Bool
}

extension AVAudioPlayer: SoundCuePlayback {}

@MainActor
protocol OneShotSoundPlaying: AnyObject {
    @discardableResult
    func play(url: URL) -> Bool
    func duration(for url: URL) -> TimeInterval?
    /// Keeps a prepared player ready for each URL and releases players for URLs no longer listed.
    func preparePlayback(for urls: Set<URL>)
    /// Drops cached state for a file whose contents changed or were removed.
    func invalidate(url: URL)
}

/// Hands a player created on the preparation queue over to the main actor.
/// The preparation queue does not touch the player after handing it over.
private final class PreparedSoundCue: @unchecked Sendable {
    let player: any SoundCuePlayback

    init(player: any SoundCuePlayback) {
        self.player = player
    }
}

/// Calls `onChange` on the main queue whenever the system default output device changes.
private final class DefaultOutputDeviceObserver: @unchecked Sendable {
    private let listener: AudioObjectPropertyListenerBlock
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        listener = { _, _ in
            MainActor.assumeIsolated {
                onChange()
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
    }
}

/// Plays sound cues from prepared players.
///
/// Creating and priming an `AVAudioPlayer` blocks for file I/O, decoder setup and
/// AudioQueue priming. Each tracked cue therefore keeps one player that was created and
/// primed on a background queue, so `play(url:)` only starts playback. A played player
/// is not reused: after playback it would be primed again on the calling thread. Instead,
/// a replacement is prepared in the background after every play.
@MainActor
final class AVAudioOneShotSoundPlayer: OneShotSoundPlaying {
    typealias PlayerFactory = @Sendable (URL) throws -> any SoundCuePlayback

    private struct CachedPlayer {
        let player: any SoundCuePlayback
        let isPrepared: Bool
    }

    private let makePlayer: PlayerFactory
    private let preparationQueue: DispatchQueue
    private var outputDeviceObserver: DefaultOutputDeviceObserver?
    private var playbackURLs: Set<URL> = []
    private var cachedPlayers: [URL: CachedPlayer] = [:]
    private var durations: [URL: TimeInterval] = [:]
    private var preparations: [URL: Task<Void, Never>] = [:]
    private var preparationGenerations: [URL: Int] = [:]
    private var activePlayers: [any SoundCuePlayback] = []

    init(
        makePlayer: @escaping PlayerFactory = { try AVAudioPlayer(contentsOf: $0) },
        preparationQueue: DispatchQueue = DispatchQueue(label: "com.typewhisper.sound-cue-preparation", qos: .utility),
        observesOutputDeviceChanges: Bool = true
    ) {
        self.makePlayer = makePlayer
        self.preparationQueue = preparationQueue
        if observesOutputDeviceChanges {
            outputDeviceObserver = DefaultOutputDeviceObserver { [weak self] in
                self?.handleDefaultOutputDeviceChange()
            }
        }
    }

    @discardableResult
    func play(url: URL) -> Bool {
        defer { preparePlayer(for: url) }
        if let cached = cachedPlayers.removeValue(forKey: url),
           start(cached.player, needsPreparation: !cached.isPrepared) {
            return true
        }

        guard let player = try? makePlayer(url) else { return false }
        durations[url] = player.duration
        return start(player, needsPreparation: true)
    }

    func duration(for url: URL) -> TimeInterval? {
        if let duration = durations[url] {
            return duration
        }
        guard let player = try? makePlayer(url) else { return nil }
        durations[url] = player.duration
        if cachedPlayers[url] == nil {
            // Keep the player so the next play(url:) does not create another one.
            cachedPlayers[url] = CachedPlayer(player: player, isPrepared: false)
        }
        return player.duration
    }

    func preparePlayback(for urls: Set<URL>) {
        for url in playbackURLs.subtracting(urls) {
            discardCachedPlayer(for: url)
        }
        playbackURLs = urls
        for url in urls {
            preparePlayer(for: url)
        }
    }

    func invalidate(url: URL) {
        discardCachedPlayer(for: url)
        durations[url] = nil
        preparePlayer(for: url)
    }

    func handleDefaultOutputDeviceChange() {
        let urls = playbackURLs.union(cachedPlayers.keys)
        for url in urls {
            discardCachedPlayer(for: url)
            preparePlayer(for: url)
        }
    }

    func waitForPendingPreparationsForTesting() async {
        while let preparation = preparations.values.first {
            await preparation.value
        }
    }

    private func start(_ player: any SoundCuePlayback, needsPreparation: Bool) -> Bool {
        if needsPreparation {
            player.prepareToPlay()
        }
        guard player.play() else { return false }
        activePlayers.append(player)
        release(player, after: player.duration)
        return true
    }

    private func preparePlayer(for url: URL) {
        guard playbackURLs.contains(url),
              cachedPlayers[url] == nil,
              preparations[url] == nil else {
            return
        }

        let generation = preparationGenerations[url, default: 0]
        let makePlayer = makePlayer
        let preparationQueue = preparationQueue
        preparations[url] = Task { [weak self] in
            let cue = await withCheckedContinuation { (continuation: CheckedContinuation<PreparedSoundCue?, Never>) in
                preparationQueue.async {
                    continuation.resume(returning: AVAudioOneShotSoundPlayer.makePreparedCue(for: url, using: makePlayer))
                }
            }
            self?.finishPreparation(for: url, generation: generation, cue: cue)
        }
    }

    private func finishPreparation(for url: URL, generation: Int, cue: PreparedSoundCue?) {
        guard preparationGenerations[url, default: 0] == generation else { return }
        preparations[url] = nil
        guard let cue else { return }
        durations[url] = cue.player.duration
        if cachedPlayers[url]?.isPrepared != true {
            cachedPlayers[url] = CachedPlayer(player: cue.player, isPrepared: true)
        }
    }

    private func discardCachedPlayer(for url: URL) {
        preparationGenerations[url, default: 0] += 1
        preparations.removeValue(forKey: url)?.cancel()
        cachedPlayers[url] = nil
    }

    private nonisolated static func makePreparedCue(for url: URL, using makePlayer: PlayerFactory) -> PreparedSoundCue? {
        guard let player = try? makePlayer(url) else { return nil }
        player.prepareToPlay()
        return PreparedSoundCue(player: player)
    }

    private func release(_ player: any SoundCuePlayback, after duration: TimeInterval) {
        let nanoseconds = UInt64(max(duration + 0.5, 0.5) * 1_000_000_000)
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let player else { return }
            self?.activePlayers.removeAll { $0 === player }
        }
    }
}

@MainActor
class SoundService {
    private var sounds: [SoundEvent: NSSound] = [:]
    private var choices: [SoundEvent: SoundChoice] = [:]
    private var resolvedSounds: [SoundChoice: NSSound] = [:]
    private var previewSound: NSSound?
    private let oneShotPlayer: OneShotSoundPlaying

    init(oneShotPlayer: OneShotSoundPlaying = AVAudioOneShotSoundPlayer()) {
        self.oneShotPlayer = oneShotPlayer
        preloadSounds()
        loadChoices()
        prepareFilePlayback()
    }

    @discardableResult
    func play(_ event: SoundEvent, enabled: Bool) -> Bool {
        guard enabled else { return false }
        let choice = choices[event] ?? event.defaultChoice
        if let playbackURL = filePlaybackURL(for: choice),
           oneShotPlayer.play(url: playbackURL) {
            return true
        }
        guard let sound = sound(for: choice) else { return false }
        sound.stop()
        return sound.play()
    }

    func playbackDuration(for event: SoundEvent, enabled: Bool) -> TimeInterval? {
        guard enabled else { return nil }
        let choice = choices[event] ?? event.defaultChoice
        if let playbackURL = filePlaybackURL(for: choice),
           let duration = oneShotPlayer.duration(for: playbackURL) {
            return duration
        }
        return sound(for: choice)?.duration
    }

    func choice(for event: SoundEvent) -> SoundChoice {
        choices[event] ?? event.defaultChoice
    }

    func updateChoice(for event: SoundEvent, choice: SoundChoice) {
        choices[event] = choice
        UserDefaults.standard.set(choice.storageKey, forKey: event.userDefaultsKey)
        prepareFilePlayback()
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
        defer { oneShotPlayer.invalidate(url: destination) }
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
        oneShotPlayer.invalidate(url: path)
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

    private func filePlaybackURL(for choice: SoundChoice) -> URL? {
        switch choice {
        case .bundled(let name):
            return Bundle.main.url(forResource: name, withExtension: "wav")
        case .system(let name):
            let url = URL(fileURLWithPath: "/System/Library/Sounds")
                .appendingPathComponent(name)
                .appendingPathExtension("aiff")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .custom(let filename):
            let url = SoundChoice.customSoundsDirectory.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .none:
            return nil
        }
    }

    private func prepareFilePlayback() {
        let urls = SoundEvent.allCases.compactMap { filePlaybackURL(for: choice(for: $0)) }
        oneShotPlayer.preparePlayback(for: Set(urls))
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
