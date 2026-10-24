import AppKit
import ApplicationServices
import XCTest
@testable import TypeWhisper

/// 重复插入的修复在真实文本字段上的表现：窗口里放一个真实的 NSTextView，
/// 修复代码通过本进程的辅助功能接口读取和修改它，字段不做任何替身。
@MainActor
final class DuplicateInsertionRealFieldTests: XCTestCase {
    private var window: NSWindow!
    private var textView: NSTextView!

    override func setUp() async throws {
        try await super.setUp()
        guard AXIsProcessTrusted() else {
            throw XCTSkip("测试宿主没有辅助功能授权，无法通过 AX 操作本进程的文本字段")
        }
        let scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView
        textView.isEditable = true
        textView.allowsUndo = true
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(textView))
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        textView = nil
        try await super.tearDown()
    }

    private func focusedElementOfThisProcess() -> AXUIElement? {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private func makeService(paste: @escaping () -> Void) throws -> TextInsertionService {
        let element = try XCTUnwrap(focusedElementOfThisProcess(), "本进程没有可通过 AX 读取的焦点元素")
        let service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { NSPasteboard.withUniqueName() }
        service.pasteVerificationAttempts = 20
        service.pasteVerificationPollingDelay = .milliseconds(20)
        service.focusedTextElementOverride = { element }
        service.pasteSimulatorOverride = paste
        return service
    }

    /// 目标应用把一次粘贴应用了两次：真实字段里的第二份被删除，字段只剩一份文本。
    func testDuplicatePasteIsReducedToOneCopyInARealTextView() async throws {
        textView.string = "开始"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let text = "你好世界"
        let view = try XCTUnwrap(textView)
        let service = try makeService(paste: {
            view.insertText(text, replacementRange: view.selectedRange())
            view.insertText(text, replacementRange: view.selectedRange())
        })

        let result = try await service.insertText(text, detectMissedTextField: true)

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(textView.string, "开始你好世界")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    /// 只落地一份时，真实字段保持原样。
    func testSinglePasteLeavesARealTextViewUntouched() async throws {
        textView.string = "开始"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let text = "你好世界"
        let view = try XCTUnwrap(textView)
        let service = try makeService(paste: {
            view.insertText(text, replacementRange: view.selectedRange())
        })

        let result = try await service.insertText(text, detectMissedTextField: true)

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(textView.string, "开始你好世界")
    }

    /// 字段里还有别的内容时，真实字段里不删除任何内容。
    func testUnexpectedContentIsLeftUntouchedInARealTextView() async throws {
        textView.string = "开始"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let text = "你好世界"
        let view = try XCTUnwrap(textView)
        let service = try makeService(paste: {
            view.insertText(text + text + "另外的内容", replacementRange: view.selectedRange())
        })

        let result = try await service.insertText(text, detectMissedTextField: true)

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(textView.string, "开始你好世界你好世界另外的内容")
    }
}
