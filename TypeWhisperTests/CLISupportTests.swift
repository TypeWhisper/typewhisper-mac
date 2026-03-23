import Foundation
import XCTest

final class CLISupportTests: XCTestCase {
    func testOutputFormatterRendersHumanReadableStatusAndModels() {
        let statusJSON = Data(#"{"status":"ready","engine":"parakeet","model":"tiny"}"#.utf8)
        let modelsJSON = Data(#"{"models":[{"id":"tiny","engine":"parakeet","name":"Tiny","status":"ready","selected":true}]}"#.utf8)

        XCTAssertEqual(OutputFormatter.formatStatus(statusJSON, json: false), "Ready - parakeet (tiny)")
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("tiny"))
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("*"))
    }

    func testPortDiscoveryUsesConfiguredPortFileAndFallback() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("TypeWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)

        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9911)
        XCTAssertEqual(PortDiscovery.discoverPort(dev: true, applicationSupportDirectory: applicationSupportRoot), PortDiscovery.defaultPort)
    }
}
