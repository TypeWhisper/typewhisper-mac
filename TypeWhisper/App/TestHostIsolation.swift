import Foundation
import ObjectiveC

/// Keeps unit-test runs out of the app's own preferences.
///
/// XCTest hosts the tests in the app built from the checkout, which has the bundle identifier
/// of the developer's installed copy (`com.typewhisper.mac.dev` for Debug). Without this, every
/// write through `UserDefaults.standard`, from a test or from app code under test, changes that
/// copy's settings; a test that selects a mock engine changed the engine the dev app used.
///
/// When XCTest hosts the process, `UserDefaults.standard` returns the defaults of a preferences
/// domain that belongs to this run alone and starts empty. The argument, global and registration
/// domains are still searched, so launch arguments such as `-AppleLanguages` keep working. The
/// test bundle removes the domain when it finishes.
enum TestHostIsolation {
    /// Unique per process, so concurrent test runs on one Mac do not share preferences.
    static let defaultsSuiteName =
        "\(Bundle.main.bundleIdentifier ?? "com.typewhisper.mac").tests.\(ProcessInfo.processInfo.processIdentifier)"

    /// The defaults `UserDefaults.standard` returns in the test host, or nil outside tests.
    nonisolated(unsafe) private(set) static var isolatedDefaults: UserDefaults?

    /// Must run before anything reads `UserDefaults.standard`, so it is the first statement
    /// in `main.swift`. Does nothing unless XCTest hosts the process.
    static func isolateDefaultsIfRunningTests() {
        guard AppConstants.isRunningTests, isolatedDefaults == nil else { return }

        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            fatalError("Could not separate the test host's UserDefaults from the app's preferences")
        }

        // A reused process ID must not inherit values from a run that crashed.
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        replaceStandardDefaults(with: defaults)
        isolatedDefaults = defaults
    }

    /// Deletes the run's preferences domain. Called when the test bundle finishes.
    static func removeIsolatedDefaults() {
        isolatedDefaults?.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// 截图检查使用独立的偏好设置，避免读取或修改已安装应用的设置。
enum ScreenshotPreferencesIsolation {
    /// The defaults `UserDefaults.standard` returns in a screenshot run, or nil when the app's
    /// own domain already is the screenshot domain or this is no screenshot run.
    nonisolated(unsafe) private(set) static var isolatedDefaults: UserDefaults?

    /// Must run before anything reads `UserDefaults.standard`, right after
    /// `TestHostIsolation.isolateDefaultsIfRunningTests()` in `main.swift`.
    static func isolateDefaultsIfTakingScreenshots() {
        guard AppConstants.isScreenshotAutomation, isolatedDefaults == nil,
              let domain = domainReplacingAppPreferences(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            return
        }

        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("Could not separate the screenshot run's UserDefaults from the app's preferences")
        }

        replaceStandardDefaults(with: defaults)
        isolatedDefaults = defaults
    }

    /// The domain a screenshot run uses instead of the app's own, or nil when the app's own
    /// domain is the screenshot domain (`UserDefaults(suiteName:)` refuses the app's identifier).
    static func domainReplacingAppPreferences(bundleIdentifier: String?) -> String? {
        let domain = AppConstants.screenshotPreferencesDomain
        return bundleIdentifier == domain ? nil : domain
    }
}

/// Makes `UserDefaults.standard` return `defaults` for the rest of the process.
private func replaceStandardDefaults(with defaults: UserDefaults) {
    guard let standardGetter = class_getClassMethod(
        UserDefaults.self,
        #selector(getter: UserDefaults.standard)
    ) else {
        fatalError("Could not replace UserDefaults.standard")
    }

    let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
    method_setImplementation(standardGetter, imp_implementationWithBlock(replacement))
}
