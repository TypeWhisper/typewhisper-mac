import XCTest
@testable import TypeWhisper

final class LocalAPITokenFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        TestSupport.remove(directory)
    }

    private var tokenFile: LocalAPITokenFile {
        LocalAPITokenFile(url: directory.appendingPathComponent("dictum-Dev/local-api-token"))
    }

    private func makeAuthenticator(_ file: LocalAPITokenFile) -> LocalAPIAuthenticator {
        LocalAPIAuthenticator(
            requiresAuthentication: true,
            tokenLoader: { file.load() },
            tokenSaver: { try file.save($0) }
        )
    }

    func testMissingFileGetsNewTokenReadableOnlyByOwner() async throws {
        let file = tokenFile

        let token = try await makeAuthenticator(file).loadOrCreateToken()

        XCTAssertEqual(token.count, 43)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), token)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNextLaunchReusesSavedToken() async throws {
        let file = tokenFile
        let firstToken = try await makeAuthenticator(file).loadOrCreateToken()

        let secondToken = try await makeAuthenticator(file).loadOrCreateToken()

        XCTAssertEqual(secondToken, firstToken)
    }

    func testEmptyFileGetsNewToken() async throws {
        let file = tokenFile
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\n".utf8).write(to: file.url)

        let token = try await makeAuthenticator(file).loadOrCreateToken()

        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(file.load(), token)
    }
}
