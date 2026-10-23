import AppKit
import XCTest
@testable import TypeWhisper

/// 一次粘贴被目标应用写入两次时，插入必须收敛成一份文本。
///
/// 现实依据：2026-10-23 的多次实测中，dictum 只投递了一对合成的 Cmd+V，
/// 日志报告粘贴已验证，但文本编辑里的文稿出现了两份相同文本。
/// 只比较"字段是否变化"的验证方式无法发现这种重复。
@MainActor
final class DuplicateInsertionRepairTests: XCTestCase {
    /// 一个可读写的文本字段替身，保存值、选区和每次删除请求的选区。
    private final class FieldDouble {
        var value: String
        var selection: NSRange
        var removedRanges: [NSRange] = []
        var insertedTexts: [String] = []

        init(value: String, selection: NSRange) {
            self.value = value
            self.selection = selection
        }

        var snapshot: TextInsertionService.FocusedTextSnapshot {
            let text = value as NSString
            let selected = selection.length > 0 && NSMaxRange(selection) <= text.length
                ? text.substring(with: selection)
                : ""
            return (value: value, selectedText: selected, selectedRange: selection)
        }

        func replaceSelection(with text: String) {
            let current = value as NSString
            let safeSelection = NSMaxRange(selection) <= current.length
                ? selection
                : NSRange(location: current.length, length: 0)
            value = current.replacingCharacters(in: safeSelection, with: text)
            selection = NSRange(location: safeSelection.location + (text as NSString).length, length: 0)
        }

        func removeSelection(_ range: NSRange) {
            removedRanges.append(range)
            let current = value as NSString
            guard NSMaxRange(range) <= current.length else { return }
            value = current.replacingCharacters(in: range, with: "")
            selection = NSRange(location: range.location, length: 0)
        }
    }

    private func makeService(
        field: FieldDouble,
        paste: @escaping () -> Void
    ) -> TextInsertionService {
        let service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { NSPasteboard.withUniqueName() }
        service.pasteVerificationAttempts = 20
        service.pasteVerificationPollingDelay = .milliseconds(1)
        service.focusedTextElementOverride = { AXUIElementCreateSystemWide() }
        service.focusedTextStateOverride = { _ in field.snapshot }
        service.setSelectedRangeOverride = { _, range in
            field.selection = range
            return true
        }
        service.insertTextAtOverride = { _, text in
            if text.isEmpty {
                field.removeSelection(field.selection)
            } else {
                field.insertedTexts.append(text)
                field.replaceSelection(with: text)
            }
            return true
        }
        service.pasteSimulatorOverride = paste
        return service
    }

    /// 粘贴落地后字段里是两份相同文本时，多出的一份被删除，结果按一份文本验证通过。
    func testDuplicatePasteIsReducedToOneCopy() async throws {
        let field = FieldDouble(value: "开始", selection: NSRange(location: 2, length: 0))
        var pasteCount = 0
        let service = makeService(field: field, paste: {
            pasteCount += 1
            field.replaceSelection(with: "你好世界你好世界")
        })

        let result = try await service.insertText("你好世界", detectMissedTextField: true)

        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(field.value, "开始你好世界")
        XCTAssertEqual(field.removedRanges, [NSRange(location: 6, length: 4)])
    }

    /// 字段内容与"插入文本加一份重复"不吻合时，不删除任何内容。
    func testRepairLeavesUnexpectedTextUntouched() async throws {
        let field = FieldDouble(value: "开始", selection: NSRange(location: 2, length: 0))
        let service = makeService(field: field, paste: {
            field.replaceSelection(with: "你好世界你好世界另外的内容")
        })

        let result = try await service.insertText("你好世界", detectMissedTextField: true)

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(field.value, "开始你好世界你好世界另外的内容")
        XCTAssertTrue(field.removedRanges.isEmpty)
    }

    /// 只落地一份文本时不触发删除。
    func testSingleInsertionIsNotRepaired() async throws {
        let field = FieldDouble(value: "开始", selection: NSRange(location: 2, length: 0))
        let service = makeService(field: field, paste: {
            field.replaceSelection(with: "你好世界")
        })

        let result = try await service.insertText("你好世界", detectMissedTextField: true)

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(field.value, "开始你好世界")
        XCTAssertTrue(field.removedRanges.isEmpty)
    }
}
