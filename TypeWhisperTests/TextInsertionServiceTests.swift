import AppKit
import XCTest
@testable import TypeWhisper

final class TextInsertionServiceTests: XCTestCase {
    @MainActor
    func testRemoteSessionUsesDirectInsertAndSkipsSyntheticPaste() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = true
        service.pasteboardProvider = { pasteboard }

        var pasted = false
        service.pasteSimulatorOverride = { pasted = true }
        service.directInsertOverride = { text in
            XCTAssertEqual(text, "Hello remote")
            return true
        }

        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        let result = try await service.insertText("Hello remote", preserveClipboard: true)

        XCTAssertEqual(result, .pasted)
        XCTAssertFalse(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
    }

    @MainActor
    func testRemoteSessionFallsBackToClipboardOnly() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = true
        service.pasteboardProvider = { pasteboard }

        var pasted = false
        service.pasteSimulatorOverride = { pasted = true }
        service.directInsertOverride = { _ in false }

        let result = try await service.insertText("Clipboard fallback", preserveClipboard: true)

        XCTAssertEqual(result, .copiedOnly)
        XCTAssertFalse(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "Clipboard fallback")
    }

    @MainActor
    func testLocalSessionKeepsClipboardPastePath() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = false
        service.pasteboardProvider = { pasteboard }

        var pasted = false
        service.pasteSimulatorOverride = { pasted = true }
        service.directInsertOverride = { _ in false }

        let result = try await service.insertText("Local paste")

        XCTAssertEqual(result, .pasted)
        XCTAssertTrue(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "Local paste")
    }

    @MainActor
    func testLocalSessionPrefersDirectInsertWhenAvailable() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = false
        service.pasteboardProvider = { pasteboard }

        var pasted = false
        service.pasteSimulatorOverride = { pasted = true }
        service.directInsertOverride = { text in
            XCTAssertEqual(text, "AX first")
            return true
        }

        let result = try await service.insertText("AX first")

        XCTAssertEqual(result, .pasted)
        XCTAssertFalse(pasted)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testTerminalAppsPreferSyntheticPasteOverDirectInsert() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = false
        service.pasteboardProvider = { pasteboard }
        service.captureActiveAppOverride = { ("iTerm2", "com.googlecode.iterm2", nil) }

        var pasted = false
        service.pasteSimulatorOverride = { pasted = true }
        service.directInsertOverride = { _ in
            XCTFail("Direct insert should be skipped for terminal apps")
            return false
        }

        let result = try await service.insertText("echo hello")

        XCTAssertEqual(result, .pasted)
        XCTAssertTrue(pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "echo hello")
    }

    @MainActor
    func testCopyToClipboardPersistsWhenDirectInsertSucceeds() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()

        service.accessibilityGrantedOverride = true
        service.remoteSessionOverride = false
        service.pasteboardProvider = { pasteboard }
        service.directInsertOverride = { _ in true }

        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        let result = try await service.insertText(
            "Clipboard first",
            copyToClipboard: true,
            preserveClipboard: true
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "Clipboard first")
    }
}
