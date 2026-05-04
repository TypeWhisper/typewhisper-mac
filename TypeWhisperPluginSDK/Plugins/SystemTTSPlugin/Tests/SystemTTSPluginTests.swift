import Foundation
import TypeWhisperPluginSDKTesting
import XCTest
@testable import SystemTTSPlugin

final class SystemTTSPluginTests: XCTestCase {
    func testActivationExposesPersistedRateAndSummary() throws {
        let host = try PluginTestHostServices(defaults: ["rateWPM": 210])
        let plugin = SystemTTSPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedRateWPM, 210)
        XCTAssertTrue(plugin.settingsSummary?.contains("210 WPM") == true)
    }

    func testSelectVoicePersistsChoiceWhenVoiceExists() throws {
        let host = try PluginTestHostServices()
        let plugin = SystemTTSPlugin()
        plugin.activate(host: host)

        guard let voice = plugin.availableVoices.first else {
            throw XCTSkip("No system voices available")
        }

        plugin.selectVoice(voice.id)

        XCTAssertEqual(host.userDefault(forKey: "voiceId") as? String, voice.id)
        XCTAssertEqual(plugin.selectedVoiceId, voice.id)
    }

    func testSelectRatePersistsChoice() throws {
        let host = try PluginTestHostServices()
        let plugin = SystemTTSPlugin()
        plugin.activate(host: host)

        plugin.selectRate(175)

        XCTAssertEqual(host.userDefault(forKey: "rateWPM") as? Int, 175)
        XCTAssertEqual(plugin.selectedRateWPM, 175)
    }
}
