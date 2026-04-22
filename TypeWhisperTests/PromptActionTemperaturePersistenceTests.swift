import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class PromptActionTemperaturePersistenceTests: XCTestCase {
    func testAddActionDefaultsToInheritProviderSetting() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        service.addAction(
            name: "Rewrite",
            prompt: "Rewrite this text."
        )

        let action = try XCTUnwrap(service.promptActions.first)
        XCTAssertEqual(action.temperatureModeRaw, "inheritProviderSetting")
        XCTAssertNil(action.temperatureValue)
    }

    func testCustomTemperaturePersistsAcrossReload() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        service.addAction(
            name: "Creative",
            prompt: "Rewrite creatively.",
            temperatureModeRaw: "custom",
            temperatureValue: 0.9
        )

        let reloaded = PromptActionService(appSupportDirectory: appSupportDirectory)
        let action = try XCTUnwrap(reloaded.promptActions.first)
        XCTAssertEqual(action.temperatureModeRaw, "custom")
        XCTAssertEqual(action.temperatureValue, 0.9)
    }

    func testImportedPresetKeepsRecommendedTemperature() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = PromptActionService(appSupportDirectory: appSupportDirectory)
        let preset = try XCTUnwrap(PromptAction.presets.first { $0.name == String(localized: "preset.translate") })

        service.addPreset(preset)

        let action = try XCTUnwrap(service.promptActions.first)
        XCTAssertEqual(action.temperatureModeRaw, "custom")
        XCTAssertEqual(action.temperatureValue, 0.0)
    }
}
