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
    func testPreviewStillUsesPreviewSoundResolver() {
        let service = PreviewSoundResolverSpy()

        service.preview(.bundled("recording_start"))

        XCTAssertEqual(service.resolvedChoices, [.bundled("recording_start")])
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
        private(set) var playedURLs: [URL] = []

        func play(url: URL) -> Bool {
            playedURLs.append(url)
            return true
        }
    }

}
