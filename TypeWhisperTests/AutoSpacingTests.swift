import Foundation
import XCTest
@testable import TypeWhisper

final class AutoSpacingTests: XCTestCase {
    private var service: TextInsertionService!

    override func setUp() {
        super.setUp()
        service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.focusedTextElementOverride = { AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier) }
    }

    // MARK: - Guard conditions

    func testEmptyText_isReturnedUnchanged() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: ""), "")
    }

    func testAccessibilityNotGranted_returnsTextUnchanged() {
        service.accessibilityGrantedOverride = false
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), "beautiful")
    }

    func testNoFocusedElement_returnsTextUnchanged() {
        service.focusedTextElementOverride = { nil }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), "beautiful")
    }

    func testNoSelectedRange_returnsTextUnchanged() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: nil)
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), "beautiful")
    }

    // MARK: - Cursor at boundaries

    func testCursorAtStart_noLeftSpace() {
        // "|world" + "Hello" → "Hello world" (no prepend, append space before 'w')
        service.focusedTextStateOverride = { _ in
            (value: "world", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "Hello"), "Hello ")
    }

    func testCursorAtEnd_noRightSpace() {
        // "Hello|" + "world" → " world" (prepend space after 'o', no append)
        service.focusedTextStateOverride = { _ in
            (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "world"), " world")
    }

    // MARK: - Letter adjacency (both sides)

    func testLetterOnBothSides_prependsAndAppends() {
        // "Hello|world" + "beautiful" → " beautiful "
        service.focusedTextStateOverride = { _ in
            (value: "Helloworld", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful ")
    }

    // MARK: - Whitespace adjacency

    func testSpaceOnLeft_noPrepend() {
        // "Hello |world" cursor at 6, left is space
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 6, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), "beautiful ")
    }

    func testSpaceOnRight_noAppend() {
        // "Hello| world" cursor at 5, right is space
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    // MARK: - Inserted text already has spacing

    func testInsertedTextStartsWithSpace_noPrependEvenWithLetterOnLeft() {
        // "Hello|world" + " beautiful" → " beautiful " (text already starts with space → no extra prepend)
        service.focusedTextStateOverride = { _ in
            (value: "Helloworld", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: " beautiful"), " beautiful ")
    }

    func testInsertedTextEndsWithSpace_noAppendEvenWithLetterOnRight() {
        // "Hello|world" + "beautiful " → " beautiful " (text already ends with space → no extra append)
        service.focusedTextStateOverride = { _ in
            (value: "Helloworld", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful "), " beautiful ")
    }

    // MARK: - Punctuation-aware left-side rules

    func testOpeningParenOnLeft_noPrepend() {
        // "(|Hello" cursor after '('
        service.focusedTextStateOverride = { _ in
            (value: "(Hello", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "new"), "new ")
    }

    func testOpeningBracketOnLeft_noPrepend() {
        service.focusedTextStateOverride = { _ in
            (value: "[item", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "new"), "new ")
    }

    func testOpeningBraceOnLeft_noPrepend() {
        service.focusedTextStateOverride = { _ in
            (value: "{key", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "value"), "value ")
    }

    func testForwardSlashOnLeft_noPrepend() {
        service.focusedTextStateOverride = { _ in
            (value: "/path", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "to"), "to ")
    }

    func testNewlineOnLeft_noPrepend() {
        service.focusedTextStateOverride = { _ in
            (value: "line\nword", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "new"), "new ")
    }

    func testCommaOnLeft_prependsSpace() {
        // "Hello,|world" + "Sagar" → " Sagar world" (comma triggers prepend)
        service.focusedTextStateOverride = { _ in
            (value: "Hello,world", selectedText: nil, selectedRange: NSRange(location: 6, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "Sagar"), " Sagar ")
    }

    func testPeriodOnLeft_prependsSpace() {
        // "foo.|bar" + "test" → " test bar"
        service.focusedTextStateOverride = { _ in
            (value: "foo.bar", selectedText: nil, selectedRange: NSRange(location: 4, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "test"), " test ")
    }

    func testClosingParenOnLeft_prependsSpace() {
        // "end)|next" → " text "
        service.focusedTextStateOverride = { _ in
            (value: "end)next", selectedText: nil, selectedRange: NSRange(location: 4, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "text"), " text ")
    }

    // MARK: - Punctuation-aware right-side rules

    func testCommaOnRight_noAppend() {
        // "Hello|, world" cursor before comma → no right space
        service.focusedTextStateOverride = { _ in
            (value: "Hello, world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testPeriodOnRight_noAppend() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello. world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testExclamationOnRight_noAppend() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello! world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testQuestionOnRight_noAppend() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello? world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testClosingParenOnRight_noAppend() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello) world", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testNewlineOnRight_noAppend() {
        service.focusedTextStateOverride = { _ in
            (value: "Hello\nworld", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful")
    }

    func testOpeningParenOnRight_appendsSpace() {
        // "Hello|(next)" cursor before '(' → append space
        service.focusedTextStateOverride = { _ in
            (value: "Hello(next)", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful ")
    }

    // MARK: - Selection (non-zero length range)

    func testSelectionReplaced_spacingBasedOnSelectionBoundaries() {
        // "Hello [selected]world" — left of selection is 'o', right of selection end is 'w'
        service.focusedTextStateOverride = { _ in
            (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 5, length: 1))
        }
        // Left char = 'o' (letter) → prepend; right char = 'w' (letter) → append
        XCTAssertEqual(service.applyAutoSpacing(to: "beautiful"), " beautiful ")
    }

    // MARK: - Number adjacency

    func testDigitOnLeft_prependsSpace() {
        service.focusedTextStateOverride = { _ in
            (value: "3items", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
        }
        XCTAssertEqual(service.applyAutoSpacing(to: "more"), " more ")
    }
}
