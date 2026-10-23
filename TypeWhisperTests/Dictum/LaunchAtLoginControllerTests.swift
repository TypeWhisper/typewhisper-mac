import ServiceManagement
import XCTest
@testable import TypeWhisper

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testUserChoiceRegistersAndUnregisters() {
        let service = LoginItemHarness()
        let controller = LaunchAtLoginController(service: service)
        controller.setUserChoice(true)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(controller.isEnabled)
        controller.setUserChoice(false)
        XCTAssertEqual(service.unregistrations, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testTogglingBackAfterFailureClearsError() {
        let service = LoginItemHarness()
        service.registrationError = NSError(domain: "LoginItemHarness", code: 1)
        let controller = LaunchAtLoginController(service: service)
        controller.setUserChoice(true)
        XCTAssertNotNil(controller.lastErrorDescription)
        controller.setUserChoice(false)
        XCTAssertNil(controller.lastErrorDescription)
        XCTAssertEqual(service.unregistrations, 0)
        service.registrationError = nil
        controller.setUserChoice(true)
        XCTAssertNil(controller.lastErrorDescription)
        XCTAssertTrue(controller.isEnabled)
    }
}

@MainActor
private final class LoginItemHarness: LoginItemRegistering {
    var status: SMAppService.Status = .notRegistered
    var registrationError: Error?
    var registrations = 0
    var unregistrations = 0

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregistrations += 1
        status = .notRegistered
    }
}
