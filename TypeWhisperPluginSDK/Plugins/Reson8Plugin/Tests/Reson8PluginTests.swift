import TypeWhisperPluginSDK
import XCTest
@testable import Reson8Plugin

final class Reson8PluginTests: XCTestCase {
    func testDoesNotAdvertiseMultiLanguageHintCapability() {
        let engine: any TranscriptionEnginePlugin = Reson8Plugin()

        XCTAssertFalse(engine is LanguageHintTranscriptionEnginePlugin)
    }

    func testResolveLanguagePrefersRequestedLanguage() {
        let selection = PluginLanguageSelection(
            requestedLanguage: "nl",
            languageHints: ["de", "en"]
        )

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "nl")
    }

    func testResolveLanguageUsesFirstHintForMultipleHints() {
        let selection = PluginLanguageSelection(languageHints: ["de", "en"])

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "de")
    }

    func testResolveLanguageFallsBackToAutoDetectWithoutUsableLanguage() {
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection()))
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection(languageHints: [""])))
    }
}
