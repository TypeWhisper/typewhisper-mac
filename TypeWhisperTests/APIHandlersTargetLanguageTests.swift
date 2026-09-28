#if canImport(Translation)
import XCTest
@testable import TypeWhisper

/// Covers the `target_language` handling of the /v1/transcribe API:
/// language resolution is shared between the full-text and per-segment
/// passes, segments keep their timing/speaker metadata, the response
/// `language` reflects the target, and translation failures propagate.
@available(macOS 15, *)
final class APIHandlersTargetLanguageTests: XCTestCase {

    // MARK: - APITranslation.resolve

    func testResolveMapsTargetAndSourceLanguages() {
        let translation = APITranslation.resolve(targetCode: "de", detectedLanguage: "en")
        XCTAssertNotNil(translation)
        XCTAssertEqual(translation?.targetIdentifier, "de")
        XCTAssertEqual(translation?.target.minimalIdentifier, "de")
        XCTAssertEqual(translation?.source?.minimalIdentifier, "en")
    }

    func testResolveNormalizesTargetIdentifier() {
        // "german" is an alias; the normalized identifier is what the
        // response `language` field must carry.
        let translation = APITranslation.resolve(targetCode: "german", detectedLanguage: "en")
        XCTAssertEqual(translation?.targetIdentifier, "de")
    }

    func testResolveNilTargetReturnsNil() {
        // No target_language: response keeps source segments and language.
        XCTAssertNil(APITranslation.resolve(targetCode: nil, detectedLanguage: "en"))
    }

    func testResolveInvalidTargetReturnsNil() {
        XCTAssertNil(APITranslation.resolve(targetCode: "xx-invalid", detectedLanguage: "en"))
    }

    func testResolveInvalidSourceFallsBackToAutoDetect() {
        let translation = APITranslation.resolve(targetCode: "de", detectedLanguage: "not-a-language")
        XCTAssertNotNil(translation)
        XCTAssertNil(translation?.source)
        XCTAssertEqual(translation?.targetIdentifier, "de")
    }

    func testResolveNilDetectedLanguageFallsBackToAutoDetect() {
        let translation = APITranslation.resolve(targetCode: "de", detectedLanguage: nil)
        XCTAssertNotNil(translation)
        XCTAssertNil(translation?.source)
    }

    // MARK: - APITranslation.translateSegments

    func testTranslateSegmentsPreservesTimingSpeakerAndOrder() async throws {
        let translation = try XCTUnwrap(APITranslation.resolve(targetCode: "de", detectedLanguage: "en"))
        let segments = [
            TranscriptionSegment(text: "Hello world", start: 0.0, end: 1.5, speakerLabel: "A", speakerConfidence: 0.9),
            TranscriptionSegment(text: "How are you", start: 1.5, end: 3.25),
        ]

        var translatedTexts: [String] = []
        let out = try await APITranslation.translateSegments(segments, translation: translation) {
            text, target, source in
            translatedTexts.append(text)
            XCTAssertEqual(target.minimalIdentifier, "de")
            XCTAssertEqual(source?.minimalIdentifier, "en")
            return "[de] \(text)"
        }

        XCTAssertEqual(translatedTexts, ["Hello world", "How are you"])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "[de] Hello world")
        XCTAssertEqual(out[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(out[0].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(out[0].speakerLabel, "A")
        XCTAssertEqual(out[0].speakerConfidence, 0.9)
        XCTAssertEqual(out[1].text, "[de] How are you")
        XCTAssertEqual(out[1].start, 1.5, accuracy: 1e-9)
        XCTAssertEqual(out[1].end, 3.25, accuracy: 1e-9)
        XCTAssertNil(out[1].speakerLabel)
        XCTAssertNil(out[1].speakerConfidence)
    }

    func testTranslateSegmentsSkipsEmptyText() async throws {
        let translation = try XCTUnwrap(APITranslation.resolve(targetCode: "de", detectedLanguage: "en"))
        let segments = [
            TranscriptionSegment(text: "   ", start: 0.0, end: 1.0),
            TranscriptionSegment(text: "Hi", start: 1.0, end: 2.0),
        ]

        var callCount = 0
        let out = try await APITranslation.translateSegments(segments, translation: translation) {
            text, _, _ in
            callCount += 1
            return text.uppercased()
        }

        XCTAssertEqual(callCount, 1, "blank segment text must not hit the translation service")
        XCTAssertEqual(out[0].text, "   ")
        XCTAssertEqual(out[1].text, "HI")
    }

    func testTranslateSegmentsPropagatesTranslationError() async {
        let translation = try XCTUnwrap(APITranslation.resolve(targetCode: "de", detectedLanguage: "en"))
        struct TranslationBoom: Error {}
        let segments = [TranscriptionSegment(text: "Hello", start: 0.0, end: 1.0)]

        do {
            _ = try await APITranslation.translateSegments(segments, translation: translation) {
                _, _, _ in throw TranslationBoom()
            }
            XCTFail("expected the translation error to propagate")
        } catch is TranslationBoom {
            // Expected: the API handler maps this to HTTP 500, never to
            // source-language segments presented as translated output.
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testTranslateSegmentsEmptyInput() async throws {
        let translation = try XCTUnwrap(APITranslation.resolve(targetCode: "de", detectedLanguage: "en"))
        let out = try await APITranslation.translateSegments([], translation: translation) {
            text, _, _ in return text
        }
        XCTAssertTrue(out.isEmpty)
    }
}
#endif
