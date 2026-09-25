import XCTest
@testable import TypeWhisper

final class VoiceTransformSnippetTests: XCTestCase {
    @MainActor
    private func withService(_ body: (SnippetService) throws -> Void) throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        try body(SnippetService(appSupportDirectory: directory))
    }

    @MainActor
    func testLegacyUpdatePreservesScopeAndTransformValidation() throws {
        try withService { service in
            service.addSnippet(trigger: "rewrite", replacement: "Be concise", scope: .voiceTransform)
            let snippet = try XCTUnwrap(service.snippets.first)
            service.updateSnippet(snippet, trigger: "rewrite", replacement: "Be friendly", caseSensitive: false)
            XCTAssertEqual(snippet.scope, .voiceTransform)
            XCTAssertEqual(snippet.replacement, "Be friendly")
            service.updateSnippet(snippet, trigger: "rewrite", replacement: "{clipboard}", caseSensitive: false)
            XCTAssertEqual(snippet.replacement, "Be friendly")
            snippet.scopeRawValue = "future-scope"
            service.updateSnippet(snippet, trigger: "rewrite", replacement: "Future prompt", caseSensitive: false)
            XCTAssertEqual(snippet.scopeRawValue, "future-scope")
            XCTAssertEqual(service.applySnippets(to: "rewrite"), "rewrite")
            service.updateSnippet(snippet, trigger: "rewrite", replacement: "Both prompt", caseSensitive: false, scope: .both)
            XCTAssertEqual(snippet.scope, .both)
        }
    }

    @MainActor
    func testTransformScopesKeepDictationAndInstructionsSeparate() throws {
        try withService { service in
            service.addSnippet(trigger: "my rewrite", replacement: "Be concise", scope: .voiceTransform)
            service.addSnippet(trigger: "signature", replacement: "Regards")
            service.addSnippet(trigger: "shared", replacement: "Common", scope: .both)
            XCTAssertEqual(service.applySnippets(to: "my rewrite signature shared"), "my rewrite Regards Common")
            let result = try service.resolveTransformInstruction("My rewrite, signature shared; keep dates.")
            XCTAssertEqual(result.resolved, "Be concise, signature Common; keep dates.")
            XCTAssertEqual(result.matchedTriggers, ["my rewrite", "shared"])
            XCTAssertEqual(result.original, "My rewrite, signature shared; keep dates.")
        }
    }

    @MainActor
    func testLongestMatchWholeWordsAndNoRecursiveExpansion() throws {
        try withService { service in
            service.addSnippet(trigger: "rewrite", replacement: "short", scope: .voiceTransform)
            service.addSnippet(trigger: "my rewrite", replacement: "rewrite", scope: .voiceTransform)
            service.addSnippet(trigger: "résumé", replacement: "CV", scope: .voiceTransform)
            let result = try service.resolveTransformInstruction("MY  REWRITE, rewriter rewrite résumé résumés 🙂")
            XCTAssertEqual(result.resolved, "rewrite, rewriter short CV résumés 🙂")
            XCTAssertEqual(result.matchedTriggers, ["my rewrite", "rewrite", "résumé"])
        }
    }

    @MainActor
    func testDuplicateNormalizedAliasesAndClipboardAreRejected() throws {
        try withService { service in
            service.addSnippet(trigger: "my rewrite", replacement: "Concise", scope: .voiceTransform)
            service.addSnippet(trigger: " MY   REWRITE ", replacement: "Different", scope: .both)
            service.addSnippet(trigger: "clipboard", replacement: "{{CLIPBOARD}}", scope: .voiceTransform)
            XCTAssertEqual(service.snippets.count, 1)
            XCTAssertNotNil(service.transformValidationError(trigger: "clip", replacement: "{clipboard}", scope: .both))
            XCTAssertNil(service.transformValidationError(trigger: "clip", replacement: "{clipboard}", scope: .dictation))
        }
    }

    @MainActor
    func testUnsafeSyncedSnippetsFailAtResolutionAndDisabledSnippetsAreIgnored() throws {
        try withService { service in
            let now = Date()
            try service.applyUserDataSyncMutations([.upsertSnippet(UserDataSyncSnippet(
                trigger: "unsafe", replacement: "{{CLIPBOARD}}", caseSensitive: false, isEnabled: true,
                scopeRawValue: "voiceTransform", createdAt: now, updatedAt: now
            ))])
            XCTAssertThrowsError(try service.resolveTransformInstruction("unsafe"))
            XCTAssertEqual(try service.resolveTransformInstruction("other").resolved, "other")
            service.toggleSnippet(try XCTUnwrap(service.snippets.first))
            XCTAssertEqual(try service.resolveTransformInstruction("unsafe").resolved, "unsafe")
        }
    }

    @MainActor
    func testSyncRoundTripLegacyDefaultsAndUnknownScopes() throws {
        try withService { service in
            service.addSnippet(trigger: "rewrite", replacement: "Concise", scope: .voiceTransform)
            let snapshot = try XCTUnwrap(service.userDataSyncSnippets().first)
            let roundTrip = try JSONDecoder().decode(UserDataSyncSnippet.self, from: JSONEncoder().encode(snapshot))
            XCTAssertEqual(roundTrip.scopeRawValue, "voiceTransform")
            try withService { destination in
                try destination.applyUserDataSyncMutations([.upsertSnippet(roundTrip)])
                XCTAssertEqual(destination.snippets.first?.scope, .voiceTransform)
                XCTAssertEqual(try destination.resolveTransformInstruction("rewrite").resolved, "Concise")
            }
            let legacy = Data(#"{"trigger":"old","replacement":"Expanded","caseSensitive":false,"isEnabled":true,"createdAt":0,"updatedAt":0}"#.utf8)
            let decoded = try JSONDecoder().decode(UserDataSyncSnippet.self, from: legacy)
            XCTAssertNil(decoded.scopeRawValue)
            try service.applyUserDataSyncMutations([.upsertSnippet(decoded)])
            XCTAssertEqual(service.applySnippets(to: "old"), "Expanded")
            let old = try XCTUnwrap(service.snippets.first { $0.trigger == "old" })
            old.scopeRawValue = "futureScope"
            XCTAssertNil(old.scope)
            XCTAssertEqual(service.applySnippets(to: "old"), "old")
            XCTAssertEqual(try service.resolveTransformInstruction("old").resolved, "old")
        }
    }

    func testBackupDTOReadsLegacyAndPreservesScope() throws {
        let legacy = Data(#"{"trigger":"old","replacement":"Expanded","caseSensitive":false,"isEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SettingsBackupExporter.SnippetDTO.self, from: legacy)
        XCTAssertNil(decoded.scopeRawValue)
        var current = decoded
        current.scopeRawValue = "voiceTransform"
        let roundTrip = try JSONDecoder().decode(SettingsBackupExporter.SnippetDTO.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip.scopeRawValue, "voiceTransform")
    }

    @MainActor
    func testScopePersistsAndDatePlaceholderExpands() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        do {
            let service = SnippetService(appSupportDirectory: directory)
            service.addSnippet(trigger: "dated rewrite", replacement: "Use {{DATE:yyyy-MM-dd}}", scope: .voiceTransform)
        }
        let reloaded = SnippetService(appSupportDirectory: directory)
        XCTAssertEqual(reloaded.snippets.first?.scope, .voiceTransform)
        let result = try reloaded.resolveTransformInstruction("dated rewrite; dated rewrite")
        let parts = result.resolved.components(separatedBy: "; ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first, parts.last)
        XCTAssertFalse(result.resolved.contains("{{DATE"))
        XCTAssertEqual(result.matchedTriggers, ["dated rewrite"])
    }

    @MainActor
    func testAmbiguousAliasesFromSyncFailClosed() throws {
        try withService { service in
            let now = Date()
            let mutations = ["my rewrite", "my  rewrite"].map { trigger in
                UserDataSyncMutation.upsertSnippet(UserDataSyncSnippet(
                    trigger: trigger, replacement: "Concise", caseSensitive: false, isEnabled: true,
                    scopeRawValue: "voiceTransform", createdAt: now, updatedAt: now
                ))
            }
            try service.applyUserDataSyncMutations(mutations)
            XCTAssertEqual(service.snippets.count, 2)
            XCTAssertThrowsError(try service.resolveTransformInstruction("my rewrite"))
        }
    }
}
