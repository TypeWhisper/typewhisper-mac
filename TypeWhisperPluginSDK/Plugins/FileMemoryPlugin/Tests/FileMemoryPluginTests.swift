import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import FileMemoryPlugin

final class FileMemoryPluginTests: XCTestCase {
    func testStoreSearchUpdateDeleteAndPersist() async throws {
        let host = try PluginTestHostServices()
        let plugin = FileMemoryPlugin()
        plugin.activate(host: host)

        let entry = MemoryEntry(
            content: "Remember the customer prefers markdown summaries",
            type: .preference,
            confidence: 0.9
        )

        try await plugin.store([entry])
        XCTAssertEqual(plugin.memoryCount, 1)

        let searchResults = try await plugin.search(MemoryQuery(text: "markdown customer"))
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.entry.id, entry.id)

        var updated = entry
        updated.content = "Remember the customer prefers concise markdown summaries"
        try await plugin.update(updated)

        let listed = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(listed.first?.content, updated.content)

        plugin.deactivate()

        let reloaded = FileMemoryPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(reloaded.memoryCount, 1)
        XCTAssertEqual(reloaded.getAllMemories().first?.content, updated.content)

        try await reloaded.delete([entry.id])
        XCTAssertEqual(reloaded.memoryCount, 0)

        reloaded.deactivate()
    }

    func testDeleteAllClearsPersistedEntries() async throws {
        let host = try PluginTestHostServices()
        let plugin = FileMemoryPlugin()
        plugin.activate(host: host)

        try await plugin.store([
            MemoryEntry(content: "one", type: .fact),
            MemoryEntry(content: "two", type: .context),
        ])

        try await plugin.deleteAll()
        XCTAssertEqual(plugin.memoryCount, 0)

        plugin.deactivate()

        let reloaded = FileMemoryPlugin()
        reloaded.activate(host: host)
        XCTAssertEqual(reloaded.memoryCount, 0)
    }
}
