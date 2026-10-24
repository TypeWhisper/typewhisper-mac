import XCTest
@testable import TypeWhisper

final class StyleResolutionTests: XCTestCase {
    func testUnknownAppUsesGlobalStyle() {
        let global = StyleSettings(formality: .formal, tone: .upbeat, emoji: .often, signOff: "小林")
        let style = ResolvedStyle.resolve(bundleID: "example.app", browserURL: nil, global: global, apps: AppStyle.defaults)
        XCTAssertEqual(style.formality, .formal)
        XCTAssertEqual(style.tone, .upbeat)
        XCTAssertEqual(style.signOff, "小林")
    }

    func testUserAppWinsOverBuiltInRegardlessOfOrder() {
        var apps = AppStyle.defaults
        apps.append(AppStyle(id: "personal-mail", kind: .userApp, name: "Mail", bundleIDs: ["com.apple.mail"],
                             urlPatterns: [], formality: .casual, tone: .direct, emoji: .often))
        let style = ResolvedStyle.resolve(bundleID: "com.apple.mail", browserURL: nil, global: StyleSettings(), apps: apps)
        XCTAssertEqual(style.formality, .casual)
        XCTAssertEqual(style.tone, .direct)
        XCTAssertNil(style.signOff)
    }

    func testGmailMatchesHostWithoutMatchingLookalikeDomains() {
        let global = StyleSettings()
        let mail = ResolvedStyle.resolve(bundleID: "com.google.Chrome", browserURL: "https://mail.google.com/mail/u/0/", global: global, apps: AppStyle.defaults)
        XCTAssertEqual(mail.group, .mail)
        XCTAssertEqual(mail.formality, .formal)
        let other = ResolvedStyle.resolve(bundleID: "com.google.Chrome", browserURL: "https://mail.google.com.example.org/", global: global, apps: AppStyle.defaults)
        XCTAssertNil(other.group)
        XCTAssertEqual(other.formality, global.formality)
    }
}
