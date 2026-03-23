import Foundation

enum AppConstants {
    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName: String = {
        #if DEBUG
        return "TypeWhisper-Dev"
        #else
        return "TypeWhisper"
        #endif
    }()

    static let keychainServicePrefix: String = {
        #if DEBUG
        return "com.typewhisper.mac.dev.apikey."
        #else
        return "com.typewhisper.mac.apikey."
        #endif
    }()

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        return defaultAppSupportDirectory
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    static let isDevelopment: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
}
