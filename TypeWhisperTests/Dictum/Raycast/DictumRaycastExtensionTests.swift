import XCTest
@testable import TypeWhisper

final class DictumRaycastExtensionTests: XCTestCase {
    private var extensionsDirectory: URL!

    override func setUpWithError() throws {
        extensionsDirectory = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        TestSupport.remove(extensionsDirectory)
    }

    private func installManifest(_ json: String) throws {
        let folder = extensionsDirectory.appendingPathComponent("dictum", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("package.json"))
    }

    func testImportedExtensionIsInstalled() throws {
        try installManifest(#"{"name": "dictum", "title": "dictum", "author": "schneider_vaughn"}"#)

        XCTAssertTrue(DictumRaycastExtension.isInstalled(extensionsDirectory: extensionsDirectory))
    }

    func testMissingExtensionIsNotInstalled() {
        XCTAssertFalse(DictumRaycastExtension.isInstalled(extensionsDirectory: extensionsDirectory))
    }

    func testCopyFromAnotherAuthorIsNotInstalled() throws {
        try installManifest(#"{"name": "dictum", "title": "dictum", "author": "schneidervvv"}"#)

        XCTAssertFalse(DictumRaycastExtension.isInstalled(extensionsDirectory: extensionsDirectory))
    }
}
