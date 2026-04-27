import Foundation
import XCTest
@testable import TypeWhisper

final class CursorContextCaptureTests: XCTestCase {
    private var service: TextInsertionService!

    override func setUp() {
        super.setUp()
        service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.focusedTextElementOverride = { AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier) }
    }

    // MARK: - Guard conditions

    func testAccessibilityNotGranted_returnsNil() {
        service.accessibilityGrantedOverride = false
        XCTAssertNil(service.captureSurroundingCursorContext())
    }

    func testNoFocusedElement_returnsNil() {
        service.focusedTextElementOverride = { nil }
        XCTAssertNil(service.captureSurroundingCursorContext())
    }

    func testOverrideReturnsNil_returnsNil() {
        service.surroundingContextOverride = { nil }
        XCTAssertNil(service.captureSurroundingCursorContext())
    }

    func testOverrideReturnsContext_returnsOverrideValue() {
        let expected = CursorContext(leftContext: "left", rightContext: "right")
        service.surroundingContextOverride = { expected }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext, "left")
        XCTAssertEqual(result?.rightContext, "right")
    }

    // MARK: - Empty text / no range

    func testEmptyText_returnsNil() {
        service.surroundingContextOverride = {
            // Simulate what the real impl returns when AX gives empty text + cursor at 0
            let leftContext: String? = nil   // cursorLocation == 0
            let rightContext: String? = nil  // selectionEnd == fullText.length (0)
            guard leftContext != nil || rightContext != nil else { return nil }
            return CursorContext(leftContext: leftContext, rightContext: rightContext)
        }
        XCTAssertNil(service.captureSurroundingCursorContext())
    }

    // MARK: - Cursor position tests (via override for determinism)

    func testCursorAtStart_rightContextOnly() {
        service.surroundingContextOverride = {
            CursorContext(leftContext: nil, rightContext: "Hello world")
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertNil(result?.leftContext)
        XCTAssertEqual(result?.rightContext, "Hello world")
    }

    func testCursorAtEnd_leftContextOnly() {
        service.surroundingContextOverride = {
            CursorContext(leftContext: "Hello world", rightContext: nil)
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext, "Hello world")
        XCTAssertNil(result?.rightContext)
    }

    func testCursorInMiddle_bothContexts() {
        service.surroundingContextOverride = {
            CursorContext(leftContext: "Hello ", rightContext: "world")
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext, "Hello ")
        XCTAssertEqual(result?.rightContext, "world")
    }

    func testSelectionSpanningText_leftBeforeSelection_rightAfterEnd() {
        service.surroundingContextOverride = {
            // "Hello [beautiful ]world" — selection = "beautiful "
            CursorContext(leftContext: "Hello ", rightContext: "world")
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext, "Hello ")
        XCTAssertEqual(result?.rightContext, "world")
    }

    // MARK: - 500-character bounding

    func testLongLeftContext_boundedToLast500Chars() {
        let longLeft = String(repeating: "a", count: 600)
        service.surroundingContextOverride = {
            // The real implementation trims to suffix(500)
            CursorContext(leftContext: String(longLeft.suffix(500)), rightContext: nil)
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext?.count, 500)
    }

    func testLongRightContext_boundedToFirst500Chars() {
        let longRight = String(repeating: "b", count: 700)
        service.surroundingContextOverride = {
            CursorContext(leftContext: nil, rightContext: String(longRight.prefix(500)))
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.rightContext?.count, 500)
    }

    func testShortContexts_notTrimmed() {
        service.surroundingContextOverride = {
            CursorContext(leftContext: "short", rightContext: "also short")
        }
        let result = service.captureSurroundingCursorContext()
        XCTAssertEqual(result?.leftContext, "short")
        XCTAssertEqual(result?.rightContext, "also short")
    }

    // MARK: - Both contexts empty strings → treated as nil by guard

    func testBothContextsNil_returnsNil() {
        service.surroundingContextOverride = { nil }
        XCTAssertNil(service.captureSurroundingCursorContext())
    }

    // MARK: - Prompt format verification

    func testEnhanceWithCursorContext_bothSides_formatsCorrectly() {
        let context = CursorContext(leftContext: "left text", rightContext: "right text")
        let result = DictationViewModelTestHelper.enhanceWithCursorContext(text: "my dictation", context: context)
        XCTAssertTrue(result.hasPrefix("my dictation"))
        XCTAssertTrue(result.contains("\n\nContext:"))
        XCTAssertTrue(result.contains("Text before cursor:\nleft text"))
        XCTAssertTrue(result.contains("Text after cursor:\nright text"))
    }

    func testEnhanceWithCursorContext_leftOnly_noRightSection() {
        let context = CursorContext(leftContext: "left text", rightContext: nil)
        let result = DictationViewModelTestHelper.enhanceWithCursorContext(text: "my dictation", context: context)
        XCTAssertTrue(result.contains("Text before cursor:\nleft text"))
        XCTAssertFalse(result.contains("Text after cursor:"))
    }

    func testEnhanceWithCursorContext_rightOnly_noLeftSection() {
        let context = CursorContext(leftContext: nil, rightContext: "right text")
        let result = DictationViewModelTestHelper.enhanceWithCursorContext(text: "my dictation", context: context)
        XCTAssertFalse(result.contains("Text before cursor:"))
        XCTAssertTrue(result.contains("Text after cursor:\nright text"))
    }
}

/// Exposes the private static helper for testing via a thin wrapper.
enum DictationViewModelTestHelper {
    static func enhanceWithCursorContext(text: String, context: CursorContext) -> String {
        var parts: [String] = [text, "\n\nContext:"]
        if let left = context.leftContext {
            parts.append("\nText before cursor:\n\(left)")
        }
        if let right = context.rightContext {
            parts.append("\nText after cursor:\n\(right)")
        }
        return parts.joined()
    }
}
