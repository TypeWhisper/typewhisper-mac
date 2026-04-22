import XCTest
@testable import TypeWhisperPluginSDK

final class LLMTemperatureSupportTests: XCTestCase {
    func testResolvedTemperatureUsesProviderSettingWhenInheriting() {
        let providerDirective = PluginLLMTemperatureDirective.custom(0.7)
        let resolved = providerDirective.resolvedTemperature(
            applying: .inheritProviderSetting
        )

        XCTAssertEqual(resolved, 0.7)
    }

    func testResolvedTemperatureOmitsValueForProviderDefault() {
        let providerDirective = PluginLLMTemperatureDirective.custom(0.7)
        let resolved = providerDirective.resolvedTemperature(
            applying: .providerDefault
        )

        XCTAssertNil(resolved)
    }

    func testResolvedTemperatureUsesCustomOverride() {
        let providerDirective = PluginLLMTemperatureDirective.custom(0.2)
        let resolved = providerDirective.resolvedTemperature(
            applying: .custom(1.1)
        )

        XCTAssertEqual(resolved, 1.1)
    }
}
