import XCTest
@testable import TypeWhisper

final class SetupWizardRecommendationAvailabilityTests: XCTestCase {
    func testParakeetOnIntelIsUnavailableAfterRegistryLoaded() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .unavailable(.appleSiliconOnly))
    }

    func testMissingPluginStillLoadsWhileRegistryIsLoading() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loading,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .loading)
    }

    func testCompatibleRegistryEntryCanBeInstalled() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.groq",
            isInstalled: false,
            isReady: false,
            registryPlugin: makeRegistryPlugin(id: "com.typewhisper.groq"),
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .installAvailable)
    }

    func testInstallStateTakesPrecedenceOverUnavailableRecommendation() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: .downloading(0.42),
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .installState(.downloading(0.42)))
    }

    func testReadyStateTakesPrecedenceOverUnavailableRecommendation() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: true,
            isReady: true,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .ready)
    }

    func testInstalledStateTakesPrecedenceOverUnavailableRecommendation() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: true,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .setupRequired)
    }

    func testErrorInstallStateTakesPrecedenceOverUnavailableRecommendation() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: .error("Download failed"),
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .installState(.error("Download failed")))
    }

    private func makeRegistryPlugin(id: String) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            source: .official,
            name: "Compatible Plugin",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: "v1",
            minOSVersion: "14.0",
            supportedArchitectures: nil,
            author: "TypeWhisper",
            description: "Compatible transcription engine",
            category: "transcription",
            categories: ["transcription"],
            size: 1,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            hosting: nil,
            descriptions: nil,
            downloadCount: nil
        )
    }
}
