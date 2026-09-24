import AppKit
import XCTest
@testable import TypeWhisper

final class SoundServiceTests: XCTestCase {
    func testSoundEventKeysHaveGermanLocalizationsInCatalog() throws {
        XCTAssertEqual(
            SoundEvent.recordingStarted.displayName,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Recording started")
        )
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Recording started", language: "de"), "Aufnahme gestartet")

        XCTAssertEqual(
            SoundEvent.transcriptionSuccess.displayName,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Transcription success")
        )
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Transcription success", language: "de"), "Transkription erfolgreich")
    }

    func testAccessibilityAndSpeechFeedbackKeysHaveGermanLocalizationsInCatalog() throws {
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Recording started", language: "de"), "Aufnahme gestartet")
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Prompt complete", language: "de"), "Prompt abgeschlossen")
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Processing prompt", language: "de"), "Verarbeite Prompt")
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Processing prompt: %@", language: "de"), "Verarbeite Prompt: %@")
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Error: %@", language: "de"), "Fehler: %@")
        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: "Transcription complete, %lld words", language: "de"),
            "Transkription abgeschlossen, %lld Wörter"
        )
    }

    func testCatalogLookupFallsBackToSourceStringWhenPreferredLanguageHasNoTranslation() throws {
        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: "Recording started", preferredLanguages: ["en-US"]),
            "Recording started"
        )
    }

    func testRecorderEchoHandlingLabelsUseEnglishSourceStringsWithGermanTranslations() throws {
        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: "Aggressive", preferredLanguages: ["en-US"]),
            "Aggressive"
        )
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Aggressive", language: "de"), "Aggressiv")

        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: "Medium", preferredLanguages: ["en-US"]),
            "Medium"
        )
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Medium", language: "de"), "Mittel")

        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: "Off", preferredLanguages: ["en-US"]),
            "Off"
        )
        XCTAssertEqual(try TestSupport.localizedCatalogValue(for: "Off", language: "de"), "Aus")
    }

    func testRecordingSpokenLanguageCopyIsLocalizedInCatalog() throws {
        let copy = "Controls push-to-talk dictation, workflows that inherit the global spoken language, and CLI/API defaults when they use app defaults. Recorder and Recovery have separate language settings."

        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: copy, preferredLanguages: ["en-US"]),
            copy
        )
        XCTAssertEqual(
            try TestSupport.localizedCatalogValue(for: copy, language: "de"),
            "Steuert Push-to-Talk-Diktat, Workflows, die die globale gesprochene Sprache übernehmen, und CLI/API-Standardwerte, wenn sie App-Standardwerte verwenden. Recorder und Wiederherstellung haben separate Spracheinstellungen."
        )
    }

    @MainActor
    func testSoundResolutionCachesImportedCustomSounds() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let storedDefaults = captureSoundDefaults()
        defer {
            restoreSoundDefaults(storedDefaults)
            AppConstants.testAppSupportDirectoryOverride = nil
            TestSupport.remove(appSupportDirectory)
        }

        AppConstants.testAppSupportDirectoryOverride = appSupportDirectory

        let service = SoundService()
        let filename = try service.importCustomSound(from: testSoundURL)

        let firstSound = try XCTUnwrap(service.sound(for: .custom(filename)))
        let secondSound = try XCTUnwrap(service.sound(for: .custom(filename)))

        XCTAssertTrue(firstSound === secondSound)
        XCTAssertEqual(SoundChoice.installedCustomSounds(), [filename])
    }

    @MainActor
    func testDeletingCustomSoundResetsAffectedEventChoices() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let storedDefaults = captureSoundDefaults()
        defer {
            restoreSoundDefaults(storedDefaults)
            AppConstants.testAppSupportDirectoryOverride = nil
            TestSupport.remove(appSupportDirectory)
        }

        AppConstants.testAppSupportDirectoryOverride = appSupportDirectory

        let service = SoundService()
        let filename = try service.importCustomSound(from: testSoundURL)

        service.updateChoice(for: .recordingStarted, choice: .custom(filename))
        service.updateChoice(for: .error, choice: .custom(filename))
        service.updateChoice(for: .transcriptionSuccess, choice: .system("Ping"))

        service.deleteCustomSound(filename)

        XCTAssertEqual(service.choice(for: .recordingStarted), .bundled("recording_start"))
        XCTAssertEqual(service.choice(for: .error), .bundled("error"))
        XCTAssertEqual(service.choice(for: .transcriptionSuccess), .system("Ping"))
        XCTAssertEqual(SoundChoice.installedCustomSounds(), [])
    }

    @MainActor
    func testPlayRecordingStartedUsesFilePlaybackInsteadOfPreviewSoundResolver() {
        let storedDefaults = captureSoundDefaults()
        defer { restoreSoundDefaults(storedDefaults) }

        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.soundRecordingStarted)

        let oneShotPlayer = SpyOneShotSoundPlayer()
        let service = PreviewSoundResolverSpy(oneShotPlayer: oneShotPlayer)

        service.play(.recordingStarted, enabled: true)

        XCTAssertEqual(oneShotPlayer.playedURLs.map(\.lastPathComponent), ["recording_start.wav"])
        XCTAssertTrue(service.resolvedChoices.isEmpty)
    }

    @MainActor
    func testPlayRecordingStartedUsesFilePlaybackForCustomSound() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let storedDefaults = captureSoundDefaults()
        defer {
            restoreSoundDefaults(storedDefaults)
            AppConstants.testAppSupportDirectoryOverride = nil
            TestSupport.remove(appSupportDirectory)
        }

        AppConstants.testAppSupportDirectoryOverride = appSupportDirectory
        let oneShotPlayer = SpyOneShotSoundPlayer()
        let service = PreviewSoundResolverSpy(oneShotPlayer: oneShotPlayer)
        let filename = try service.importCustomSound(from: testSoundURL)

        service.updateChoice(for: .recordingStarted, choice: .custom(filename))
        service.play(.recordingStarted, enabled: true)

        XCTAssertEqual(oneShotPlayer.playedURLs.map(\.lastPathComponent), [filename])
        XCTAssertTrue(service.resolvedChoices.isEmpty)
    }

    @MainActor
    func testPlayRecordingStartedUsesFilePlaybackForSystemSound() throws {
        let storedDefaults = captureSoundDefaults()
        defer { restoreSoundDefaults(storedDefaults) }

        let systemSoundName = try XCTUnwrap(
            SoundChoice.systemSounds.first { name in
                FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff")
            }
        )
        let oneShotPlayer = SpyOneShotSoundPlayer()
        let service = PreviewSoundResolverSpy(oneShotPlayer: oneShotPlayer)

        service.updateChoice(for: .recordingStarted, choice: .system(systemSoundName))
        service.play(.recordingStarted, enabled: true)

        XCTAssertEqual(oneShotPlayer.playedURLs.map(\.lastPathComponent), ["\(systemSoundName).aiff"])
        XCTAssertTrue(service.resolvedChoices.isEmpty)
    }

    @MainActor
    func testPlaybackDurationFallsBackToSoundResolverWhenFileDurationUnavailable() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let storedDefaults = captureSoundDefaults()
        defer {
            restoreSoundDefaults(storedDefaults)
            AppConstants.testAppSupportDirectoryOverride = nil
            TestSupport.remove(appSupportDirectory)
        }

        AppConstants.testAppSupportDirectoryOverride = appSupportDirectory
        let soundsDirectory = SoundChoice.customSoundsDirectory
        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        let filename = "invalid.wav"
        try Data("not a playable audio file".utf8).write(to: soundsDirectory.appendingPathComponent(filename))
        let service = PreviewSoundResolverSpy()
        service.updateChoice(for: .recordingStarted, choice: .custom(filename))

        XCTAssertNil(service.playbackDuration(for: .recordingStarted, enabled: true))
        XCTAssertEqual(service.resolvedChoices, [.custom(filename)])
    }

    @MainActor
    func testPlaybackDurationUsesOneShotPlayerDurationWithoutResolvingPreviewSound() {
        let storedDefaults = captureSoundDefaults()
        defer { restoreSoundDefaults(storedDefaults) }

        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.soundRecordingStarted)
        let oneShotPlayer = SpyOneShotSoundPlayer()
        oneShotPlayer.durationToReturn = 0.25
        let service = PreviewSoundResolverSpy(oneShotPlayer: oneShotPlayer)

        XCTAssertEqual(service.playbackDuration(for: .recordingStarted, enabled: true), 0.25)
        XCTAssertNil(service.playbackDuration(for: .recordingStarted, enabled: false))
        XCTAssertEqual(oneShotPlayer.durationRequests.map(\.lastPathComponent), ["recording_start.wav"])
        XCTAssertTrue(service.resolvedChoices.isEmpty)
    }

    @MainActor
    func testServicePreparesSelectedCuesAndRefreshesThemWhenChoiceChanges() {
        let storedDefaults = captureSoundDefaults()
        defer { restoreSoundDefaults(storedDefaults) }

        for event in SoundEvent.allCases {
            UserDefaults.standard.removeObject(forKey: event.userDefaultsKey)
        }
        let oneShotPlayer = SpyOneShotSoundPlayer()
        let service = SoundService(oneShotPlayer: oneShotPlayer)

        XCTAssertEqual(
            oneShotPlayer.preparedURLSets.last.map { Set($0.map(\.lastPathComponent)) },
            ["recording_start.wav", "transcription_success.wav", "error.wav"]
        )

        service.updateChoice(for: .recordingStarted, choice: .none)

        XCTAssertEqual(
            oneShotPlayer.preparedURLSets.last.map { Set($0.map(\.lastPathComponent)) },
            ["transcription_success.wav", "error.wav"]
        )
    }

    @MainActor
    func testImportingAndDeletingCustomSoundInvalidatesCachedPlayback() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let storedDefaults = captureSoundDefaults()
        defer {
            restoreSoundDefaults(storedDefaults)
            AppConstants.testAppSupportDirectoryOverride = nil
            TestSupport.remove(appSupportDirectory)
        }

        AppConstants.testAppSupportDirectoryOverride = appSupportDirectory
        let oneShotPlayer = SpyOneShotSoundPlayer()
        let service = SoundService(oneShotPlayer: oneShotPlayer)

        let filename = try service.importCustomSound(from: testSoundURL)
        let customURL = SoundChoice.customSoundsDirectory.appendingPathComponent(filename)
        XCTAssertEqual(oneShotPlayer.invalidatedURLs, [customURL])

        service.updateChoice(for: .recordingStarted, choice: .custom(filename))
        XCTAssertEqual(oneShotPlayer.preparedURLSets.last?.contains(customURL), true)

        service.deleteCustomSound(filename)
        XCTAssertEqual(oneShotPlayer.invalidatedURLs, [customURL, customURL])
        XCTAssertEqual(oneShotPlayer.preparedURLSets.last?.contains(customURL), false)
    }

    @MainActor
    func testOneShotPlayerPreparesCueOffMainThreadAndPlaysItWithoutCreatingAnotherPlayer() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/cue.wav")

        player.preparePlayback(for: [url])
        await player.waitForPendingPreparationsForTesting()

        XCTAssertEqual(factory.players.count, 1)
        XCTAssertEqual(factory.players.first?.createdOnMainThread, false)
        XCTAssertEqual(factory.players.first?.prepareCount, 1)

        XCTAssertEqual(player.duration(for: url), 0.4)
        XCTAssertTrue(player.play(url: url))

        XCTAssertEqual(factory.players.count, 1)
        XCTAssertEqual(factory.players.first?.prepareCount, 1)
        XCTAssertEqual(factory.players.first?.playCount, 1)
    }

    @MainActor
    func testOneShotPlayerPreparesReplacementSoRepeatedPlaysDoNotReusePlayingPlayer() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/cue.wav")

        player.preparePlayback(for: [url])
        await player.waitForPendingPreparationsForTesting()
        XCTAssertTrue(player.play(url: url))
        await player.waitForPendingPreparationsForTesting()
        XCTAssertTrue(player.play(url: url))

        XCTAssertEqual(factory.players.map(\.playCount), [1, 1])
        XCTAssertEqual(factory.players.map(\.createdOnMainThread), [false, false])
        XCTAssertEqual(factory.players.map(\.prepareCount), [1, 1])
    }

    @MainActor
    func testOneShotPlayerUsesDurationPlayerForPlaybackWhenCueIsNotPrepared() {
        let factory = FakeSoundCuePlayerFactory(duration: 0.3)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/untracked.wav")

        XCTAssertEqual(player.duration(for: url), 0.3)
        XCTAssertEqual(player.duration(for: url), 0.3)
        XCTAssertTrue(player.play(url: url))

        XCTAssertEqual(factory.players.count, 1)
        XCTAssertEqual(factory.players.first?.prepareCount, 1)
        XCTAssertEqual(factory.players.first?.playCount, 1)
    }

    @MainActor
    func testOneShotPlayerInvalidationDiscardsCachedPlayerAndDuration() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/custom.wav")

        player.preparePlayback(for: [url])
        await player.waitForPendingPreparationsForTesting()
        XCTAssertEqual(player.duration(for: url), 0.4)

        factory.duration = 0.9
        player.invalidate(url: url)
        await player.waitForPendingPreparationsForTesting()

        XCTAssertEqual(player.duration(for: url), 0.9)
        XCTAssertTrue(player.play(url: url))
        XCTAssertEqual(factory.players.map(\.playCount), [0, 1])
    }

    @MainActor
    func testOneShotPlayerIgnoresPreparationThatFinishesAfterInvalidation() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/custom.wav")

        // The first preparation cannot start before this test yields the main actor, so it is
        // still in flight when invalidated. It then finishes first on the serial queue.
        player.preparePlayback(for: [url])
        player.invalidate(url: url)
        await player.waitForPendingPreparationsForTesting()

        XCTAssertTrue(player.play(url: url))
        XCTAssertEqual(factory.players.map(\.playCount), [0, 1])
    }

    @MainActor
    func testOneShotPlayerReleasesCuesThatAreNoLongerSelected() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let firstURL = URL(fileURLWithPath: "/tmp/first.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/second.wav")

        player.preparePlayback(for: [firstURL])
        await player.waitForPendingPreparationsForTesting()
        player.preparePlayback(for: [secondURL])
        await player.waitForPendingPreparationsForTesting()

        XCTAssertTrue(player.play(url: firstURL))
        await player.waitForPendingPreparationsForTesting()

        // The released first cue is created on demand and is not prepared again.
        XCTAssertEqual(factory.players.map(\.url.lastPathComponent), ["first.wav", "second.wav", "first.wav"])
        XCTAssertEqual(factory.players.map(\.playCount), [0, 0, 1])
        XCTAssertEqual(factory.players.last?.createdOnMainThread, true)
    }

    @MainActor
    func testOneShotPlayerPreparesNewCueWhenOutputDeviceConfigurationChanges() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/cue.wav")

        player.preparePlayback(for: [url])
        await player.waitForPendingPreparationsForTesting()
        player.handleOutputDeviceConfigurationChange()
        await player.waitForPendingPreparationsForTesting()

        XCTAssertTrue(player.play(url: url))
        XCTAssertEqual(factory.players.map(\.playCount), [0, 1])
        XCTAssertEqual(factory.players.map(\.createdOnMainThread), [false, false])
    }

    @MainActor
    func testOneShotPlayerDiscardsPreparationStartedBeforeOutputConfigurationChange() async {
        let factory = FakeSoundCuePlayerFactory(duration: 0.4)
        let player = makeOneShotPlayer(factory: factory)
        let url = URL(fileURLWithPath: "/tmp/cue.wav")

        // E.g. a Bluetooth headset switching to HFP while the replacement cue is being primed.
        player.preparePlayback(for: [url])
        player.handleOutputDeviceConfigurationChange()
        await player.waitForPendingPreparationsForTesting()

        XCTAssertTrue(player.play(url: url))
        XCTAssertEqual(factory.players.map(\.playCount), [0, 1])
    }

    @MainActor
    func testPreviewStillUsesPreviewSoundResolver() {
        let service = PreviewSoundResolverSpy()

        service.preview(.bundled("recording_start"))

        XCTAssertEqual(service.resolvedChoices, [.bundled("recording_start")])
    }

    @MainActor
    private func makeOneShotPlayer(factory: FakeSoundCuePlayerFactory) -> AVAudioOneShotSoundPlayer {
        AVAudioOneShotSoundPlayer(
            makePlayer: { try factory.makePlayer(url: $0) },
            preparationQueue: DispatchQueue(label: "SoundServiceTests.preparation"),
            observesOutputDeviceChanges: false
        )
    }

    private var testSoundURL: URL {
        TestSupport.repoRoot.appendingPathComponent("TypeWhisper/Resources/Sounds/error.wav", isDirectory: false)
    }

    private func captureSoundDefaults() -> [String: String?] {
        [
            UserDefaultsKeys.soundRecordingStarted: UserDefaults.standard.string(forKey: UserDefaultsKeys.soundRecordingStarted),
            UserDefaultsKeys.soundTranscriptionSuccess: UserDefaults.standard.string(forKey: UserDefaultsKeys.soundTranscriptionSuccess),
            UserDefaultsKeys.soundError: UserDefaults.standard.string(forKey: UserDefaultsKeys.soundError)
        ]
    }

    private func restoreSoundDefaults(_ values: [String: String?]) {
        for (key, value) in values {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    @MainActor
    private final class PreviewSoundResolverSpy: SoundService {
        private(set) var resolvedChoices: [SoundChoice] = []

        override func sound(for choice: SoundChoice) -> NSSound? {
            resolvedChoices.append(choice)
            return nil
        }
    }

    @MainActor
    private final class SpyOneShotSoundPlayer: OneShotSoundPlaying {
        var durationToReturn: TimeInterval?
        private(set) var playedURLs: [URL] = []
        private(set) var durationRequests: [URL] = []
        private(set) var preparedURLSets: [Set<URL>] = []
        private(set) var invalidatedURLs: [URL] = []

        func play(url: URL) -> Bool {
            playedURLs.append(url)
            return true
        }

        func duration(for url: URL) -> TimeInterval? {
            durationRequests.append(url)
            return durationToReturn
        }

        func preparePlayback(for urls: Set<URL>) {
            preparedURLSets.append(urls)
        }

        func invalidate(url: URL) {
            invalidatedURLs.append(url)
        }
    }

    private final class FakeSoundCuePlayer: SoundCuePlayback, @unchecked Sendable {
        let url: URL
        let duration: TimeInterval
        let createdOnMainThread = Thread.isMainThread
        private(set) var prepareCount = 0
        private(set) var playCount = 0

        init(url: URL, duration: TimeInterval) {
            self.url = url
            self.duration = duration
        }

        func prepareToPlay() -> Bool {
            prepareCount += 1
            return true
        }

        func play() -> Bool {
            playCount += 1
            return true
        }
    }

    private final class FakeSoundCuePlayerFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var currentDuration: TimeInterval
        private var createdPlayers: [FakeSoundCuePlayer] = []

        init(duration: TimeInterval) {
            currentDuration = duration
        }

        var duration: TimeInterval {
            get { lock.withLock { currentDuration } }
            set { lock.withLock { currentDuration = newValue } }
        }

        var players: [FakeSoundCuePlayer] {
            lock.withLock { createdPlayers }
        }

        func makePlayer(url: URL) throws -> any SoundCuePlayback {
            lock.withLock {
                let player = FakeSoundCuePlayer(url: url, duration: currentDuration)
                createdPlayers.append(player)
                return player
            }
        }
    }

}
