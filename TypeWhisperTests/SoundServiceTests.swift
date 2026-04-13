import XCTest
@testable import TypeWhisper

final class SoundServiceTests: XCTestCase {
    func testSoundEventKeysHaveGermanLocalizationsInCatalog() throws {
        XCTAssertEqual(SoundEvent.recordingStarted.displayName, "Recording started")
        XCTAssertEqual(try localizedCatalogValue(for: "Recording started", language: "de"), "Aufnahme gestartet")

        XCTAssertEqual(SoundEvent.transcriptionSuccess.displayName, "Transcription success")
        XCTAssertEqual(try localizedCatalogValue(for: "Transcription success", language: "de"), "Transkription erfolgreich")
    }

    func testAccessibilityAndSpeechFeedbackKeysHaveGermanLocalizationsInCatalog() throws {
        XCTAssertEqual(try localizedCatalogValue(for: "Recording started", language: "de"), "Aufnahme gestartet")
        XCTAssertEqual(try localizedCatalogValue(for: "Prompt complete", language: "de"), "Prompt abgeschlossen")
        XCTAssertEqual(try localizedCatalogValue(for: "Processing prompt", language: "de"), "Verarbeite Prompt")
        XCTAssertEqual(try localizedCatalogValue(for: "Processing prompt: %@", language: "de"), "Verarbeite Prompt: %@")
        XCTAssertEqual(try localizedCatalogValue(for: "Error: %@", language: "de"), "Fehler: %@")
        XCTAssertEqual(
            try localizedCatalogValue(for: "Transcription complete, %lld words", language: "de"),
            "Transkription abgeschlossen, %lld Wörter"
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

    private func localizedCatalogValue(for key: String, language: String) throws -> String {
        let data = try Data(contentsOf: TestSupport.repoRoot.appendingPathComponent("TypeWhisper/Resources/Localizable.xcstrings"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry for key: \(key)")
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for key: \(key)")
        let languageEntry = try XCTUnwrap(localizations[language] as? [String: Any], "Missing \(language) localization for key: \(key)")
        let stringUnit = try XCTUnwrap(languageEntry["stringUnit"] as? [String: Any], "Missing stringUnit for key: \(key)")
        return try XCTUnwrap(stringUnit["value"] as? String, "Missing localized value for key: \(key)")
    }
}
