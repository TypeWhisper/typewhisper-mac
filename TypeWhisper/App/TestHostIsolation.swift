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
/// domains are still searched, so launch arguments such as `-AppleLanguages` keep working.
///
/// 测试包结束时清空这个域和测试创建的套件；偏好设置文件由下一次测试宿主启动时清理。
/// `NSPasteboard.general` 同样被替换，测试不会读取或清空正在使用这台 Mac 的人的剪贴板。
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
        removeDomainsOfEndedRuns()

        replaceStandardDefaults(with: defaults)
        isolatedDefaults = defaults
        recordSuitesCreatedByTests()
        isolateGeneralPasteboard()
    }

    /// 测试包结束时调用。进程里仍存活的 UserDefaults 对象会在文件删除后再写出一个空文件，
    /// 所以这里清空域，文件留给下一次测试宿主启动时按清单在本进程结束后删除。
    static func removeIsolatedDefaults() {
        let names = createdSuiteNames.withLock { $0 }
        for name in names {
            removeDomain(name)
        }
        removeDomain(defaultsSuiteName)
        isolatedPasteboard?.releaseGlobally()
    }

    /// 只删除测试自己的域：名称不能带路径，不能是应用或系统的域，对应文件必须直接位于偏好设置文件夹里。
    /// 清单和文件夹扫描都可能带来任意名称，所以删除前在这里把关。
    /// 清空偏好设置域后，系统仍会在偏好设置文件夹里留下一个空文件，所以文件也一并删除。
    static func removeDomain(_ name: String, preferencesDirectory directory: URL = preferencesDirectory) {
        guard let file = preferencesFile(forDomain: name, in: directory, appDomain: Bundle.main.bundleIdentifier) else { return }

        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: file)
    }

    private static let protectedDomains: Set<String> = [
        "com.schneidervvv.dictum",
        "com.schneidervvv.dictum.dev",
        UserDefaults.globalDomain,
        ".GlobalPreferences",
    ]

    static func isTestOwnedName(_ name: String, appDomain: String?) -> Bool {
        !name.contains("/")
            && !name.contains("..")
            && !isProtectedName(name, appDomain: appDomain)
    }

    /// 本机的文件系统大小写不敏感，偏好设置域同样按大小写不敏感匹配，所以保护名单的比较忽略大小写。
    private static func isProtectedName(_ name: String, appDomain: String?) -> Bool {
        protectedDomains.contains { name.compare($0, options: .caseInsensitive) == .orderedSame }
            || appDomain.map { name.compare($0, options: .caseInsensitive) == .orderedSame } == true
    }

    /// 名称和文件位置检查合在一个纯函数里：名称可接受且对应文件直接位于该偏好设置文件夹时返回文件。
    /// `removeDomain` 在任何删除或同步操作之前调用它。
    static func preferencesFile(forDomain name: String, in directory: URL, appDomain: String?) -> URL? {
        guard isTestOwnedName(name, appDomain: appDomain) else { return nil }
        let file = directory.appendingPathComponent(name + ".plist")
        guard file.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        return file
    }

    static var preferencesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// 每个测试宿主在自己的进程号下留一份套件清单，进程结束后由后续启动的宿主按清单清理。
    static var suiteManifestDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TypeWhisper-TestHost-Suites", isDirectory: true)
    }

    /// 把名称并入本进程号已有的清单：复用已结束进程号的宿主会保留前一个宿主崩溃时留下的套件名。
    static func appendToSuiteManifest(_ names: Set<String>, in directory: URL) {
        let url = manifestURL(in: directory, processID: ProcessInfo.processInfo.processIdentifier)
        let existing = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        guard let data = try? JSONEncoder().encode(names.union(existing).sorted()) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func manifestURL(in directory: URL, processID: pid_t) -> URL {
        directory.appendingPathComponent("\(processID).json")
    }

    static func processHasEnded(_ processID: pid_t) -> Bool {
        kill(processID, 0) != 0 && errno == ESRCH
    }

    /// 真实焦点元素属于正在使用这台 Mac 的人，测试宿主读取它会把那个应用的字段
    /// 内容带进测试结果。测试只接受本进程的元素，其余一律拒绝。
    static func focusedElementBelongsToTestHost(_ processIdentifier: pid_t) -> Bool {
        processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// 测试用例创建的偏好设置套件只在运行结束时才能知道哪些需要删除，所以创建时记录下来。
    static let createdSuiteNames = OSAllocatedUnfairLock(initialState: Set<String>())

    /// 测试宿主的通用剪贴板，只属于这次运行。
    nonisolated(unsafe) private static var isolatedPasteboard: NSPasteboard?

    /// 记录测试代码创建的、运行前并不存在的偏好设置套件。系统框架也会用空域调用这个初始化方法，
    /// 它们的域不属于测试，所以只记录调用方在测试包里的套件。应用自己的域和全局域不记录。
    private static func recordSuitesCreatedByTests() {
        let selector = NSSelectorFromString("initWithSuiteName:")
        guard let method = class_getInstanceMethod(UserDefaults.self, selector) else { return }

        typealias Initializer = @convention(c) (AnyObject, Selector, NSString?) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
        let appDomain = Bundle.main.bundleIdentifier
        let replacement: @convention(block) (AnyObject, NSString?) -> AnyObject? = { object, name in
            if let name = name as String?,
               shouldRecordSuite(
                   named: name,
                   appDomain: appDomain,
                   exists: isolatedDefaults?.persistentDomain(forName: name) != nil,
                   callerIsInTestBundle: { callerIsInTestBundle() }
               ) {
                // 创建时就写入清单，宿主崩溃时来不及清理的套件也会被下一次启动删除。
                createdSuiteNames.withLock { names in
                    if names.insert(name).inserted {
                        appendToSuiteManifest([name], in: suiteManifestDirectory)
                    }
                }
            }
            return original(object, selector, name)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    static func shouldRecordSuite(
        named name: String,
        appDomain: String?,
        exists: @autoclosure () -> Bool,
        callerIsInTestBundle: () -> Bool
    ) -> Bool {
        isTestOwnedName(name, appDomain: appDomain)
            && !exists()
            && callerIsInTestBundle()
    }

    nonisolated(unsafe) private static let ownImage: UnsafeRawPointer = #dsohandle

    /// 调用栈上第一个不在本映像里的帧所在的映像是测试包时返回 true。
    /// 栈里属于本映像的帧是替换后的初始化方法自己，以及测试直接调用的应用代码。
    static func callerIsInTestBundle() -> Bool {
        for address in Thread.callStackReturnAddresses {
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address.uintValue),
                  dladdr(pointer, &info) != 0,
                  UnsafeRawPointer(info.dli_fbase) != ownImage else { continue }
            return String(cString: info.dli_fname).contains("/TypeWhisperTests.xctest/")
        }
        return false
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

    /// 崩溃或被终止的测试运行来不及删除自己的偏好设置域，下一次启动时按进程号清理；
    /// 正常结束的运行留下了套件清单，按清单删除它列出的套件。
    static func removeDomainsOfEndedRuns(
        manifestDirectory: URL = suiteManifestDirectory,
        preferencesDirectory directory: URL = preferencesDirectory
    ) {
        let prefix = defaultsSuiteName.split(separator: ".").dropLast().joined(separator: ".") + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for fileName in names where fileName.hasPrefix(prefix) && fileName.hasSuffix(".plist") {
            let domain = String(fileName.dropLast(".plist".count))
            guard let processID = pid_t(domain.dropFirst(prefix.count)),
                  processID != ProcessInfo.processInfo.processIdentifier,
                  processHasEnded(processID) else { continue }
            removeDomain(domain, preferencesDirectory: directory)
        }

        let manifests = (try? FileManager.default.contentsOfDirectory(at: manifestDirectory, includingPropertiesForKeys: nil)) ?? []
        for manifest in manifests where manifest.pathExtension == "json" {
            guard let processID = pid_t(manifest.deletingPathExtension().lastPathComponent),
                  processID != ProcessInfo.processInfo.processIdentifier,
                  processHasEnded(processID) else { continue }
            let suiteNames = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            for name in suiteNames {
                removeDomain(name, preferencesDirectory: directory)
            }
            try? FileManager.default.removeItem(at: manifest)
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
