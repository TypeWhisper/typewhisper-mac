import Foundation
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LiveTranscriptPlugin

@MainActor
final class LiveTranscriptPluginTests: XCTestCase {
    private func displayedText(from viewModel: LiveTranscriptViewModel) -> String {
        viewModel.paragraphs.map(\.text).joined(separator: " ")
    }

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

    func testViewModelPreservesCumulativeTranscriptUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("First sentence. Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }

    func testViewModelAppendsDisjointSegmentUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }

    func testViewModelMergesOverlappingSlidingWindowUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("Second sentence. Third sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence. Third sentence.")
    }

    func testViewModelIgnoresShorterResetUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }
}
