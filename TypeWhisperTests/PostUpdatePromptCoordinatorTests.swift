import XCTest
@testable import TypeWhisper

final class InitialWindowPresentationPolicyTests: XCTestCase {
    func testSetupHasPriorityOverWhatsNew() {
        XCTAssertEqual(InitialWindowPresentationPolicy.presentation(
            setupWizardRequired: true, whatsNewPending: true
        ), .setup)
    }

    func testUnreadWhatsNewOpensWithoutAnAccountPrompt() {
        XCTAssertEqual(InitialWindowPresentationPolicy.presentation(
            setupWizardRequired: false, whatsNewPending: true
        ), .whatsNew)
    }

    func testLaunchWithoutPendingContentStaysWindowless() {
        XCTAssertEqual(InitialWindowPresentationPolicy.presentation(
            setupWizardRequired: false, whatsNewPending: false
        ), .none)
    }
}
