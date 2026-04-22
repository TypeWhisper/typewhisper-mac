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

}
