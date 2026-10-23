import AppKit
import Foundation
import ObjectiveC
import os

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
/// test bundle removes the domain, and the suites the tests created, when it finishes.
/// `NSPasteboard.general` is replaced the same way, so tests never read or clear the clipboard
/// of the person using the Mac.
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
        removeDomainsOfEndedRuns(using: defaults)

        replaceStandardDefaults(with: defaults)
        isolatedDefaults = defaults
        recordSuitesCreatedByTests()
        isolateGeneralPasteboard()
    }

    /// Deletes the run's preferences domain and every suite the tests created.
    /// Called when the test bundle finishes.
    static func removeIsolatedDefaults() {
        isolatedDefaults?.removePersistentDomain(forName: defaultsSuiteName)
        for name in createdSuiteNames.withLock({ $0 }) {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        isolatedPasteboard?.releaseGlobally()
    }

    /// 测试用例创建的偏好设置套件只在运行结束时才能知道哪些需要删除，所以创建时记录下来。
    static let createdSuiteNames = OSAllocatedUnfairLock(initialState: Set<String>())

    /// 测试宿主的通用剪贴板，只属于这次运行。
    nonisolated(unsafe) private static var isolatedPasteboard: NSPasteboard?

    /// 记录测试创建的、运行前并不存在的偏好设置套件。应用自己的域和全局域不记录。
    private static func recordSuitesCreatedByTests() {
        let selector = NSSelectorFromString("initWithSuiteName:")
        guard let method = class_getInstanceMethod(UserDefaults.self, selector) else { return }

        typealias Initializer = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let appDomain = Bundle.main.bundleIdentifier
        let replacement: @convention(block) (AnyObject, NSString?) -> AnyObject? = { object, name in
            if let name = name as String?,
               name != appDomain,
               name != UserDefaults.globalDomain,
               !name.hasPrefix("/"),
               isolatedDefaults?.persistentDomain(forName: name) == nil {
                createdSuiteNames.withLock { _ = $0.insert(name) }
            }
            return original(object, selector, name)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// 测试宿主与已安装的应用共用剪贴板，写入或清空剪贴板会破坏正在进行的粘贴。
    /// `NSPasteboard.general` 在测试宿主里返回只属于这次运行的剪贴板。
    private static func isolateGeneralPasteboard() {
        guard let generalGetter = class_getClassMethod(
            NSPasteboard.self,
            #selector(getter: NSPasteboard.general)
        ) else {
            fatalError("Could not replace NSPasteboard.general")
        }

        let pasteboard = NSPasteboard.withUniqueName()
        let replacement: @convention(block) (AnyObject) -> NSPasteboard = { _ in pasteboard }
        method_setImplementation(generalGetter, imp_implementationWithBlock(replacement))
        isolatedPasteboard = pasteboard
    }

    /// 崩溃或被终止的测试运行来不及删除自己的偏好设置域，下一次启动时按进程号清理。
    private static func removeDomainsOfEndedRuns(using defaults: UserDefaults) {
        let prefix = defaultsSuiteName.split(separator: ".").dropLast().joined(separator: ".") + "."
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for fileName in names where fileName.hasPrefix(prefix) && fileName.hasSuffix(".plist") {
            let domain = String(fileName.dropLast(".plist".count))
            guard let processID = pid_t(domain.dropFirst(prefix.count)),
                  processID != ProcessInfo.processInfo.processIdentifier,
                  kill(processID, 0) != 0, errno == ESRCH else { continue }
            defaults.removePersistentDomain(forName: domain)
        }
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
