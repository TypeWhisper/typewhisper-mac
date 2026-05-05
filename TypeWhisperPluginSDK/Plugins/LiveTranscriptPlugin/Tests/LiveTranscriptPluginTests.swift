import Foundation
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LiveTranscriptPlugin

@MainActor
final class LiveTranscriptPluginTests: XCTestCase {
    func testAutoOpenDefaultsToDisabledWhenUnset() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertNil(host.userDefault(forKey: "autoOpen"))
        XCTAssertEqual(host.streamingDisplayActiveValues, [])
        XCTAssertEqual(eventBus.subscriberCount, 1)
    }

    func testStoredAutoOpenTrueIsPreservedOnActivation() throws {
        let host = try PluginTestHostServices(defaults: ["autoOpen": true])
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testEnablingAutoOpenRegistersStreamingDisplayExactlyOnce() throws {
        let host = try PluginTestHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateAutoOpenPreference(true)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(host.userDefault(forKey: "autoOpen") as? Bool, true)
        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testDeactivationUnsubscribesAndClearsStreamingDisplay() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(eventBus.subscriberCount, 1)

        plugin.deactivate()

        XCTAssertEqual(host.streamingDisplayActiveValues, [true, false])
        XCTAssertEqual(eventBus.subscriberCount, 0)
    }
}
