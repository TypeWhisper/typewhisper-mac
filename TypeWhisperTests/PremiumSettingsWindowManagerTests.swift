import AppKit
import SwiftUI
import XCTest
@testable import TypeWhisper

@MainActor
final class PremiumSettingsWindowManagerTests: XCTestCase {
    func testFactoriesStayLazyAndOnlyBuildTheRequestedDestination() {
        var calls: [PremiumSettingsDestination: Int] = [:]
        let factories = PremiumSettingsWindowFactories(
            access: {
                calls[.access, default: 0] += 1
                return self.definition(for: .access)
            },
            calendarMeeting: {
                calls[.calendarMeeting, default: 0] += 1
                return self.definition(for: .calendarMeeting)
            },
            correctionLearning: {
                calls[.correctionLearning, default: 0] += 1
                return self.definition(for: .correctionLearning)
            },
            cloudSync: {
                calls[.cloudSync, default: 0] += 1
                return self.definition(for: .cloudSync)
            }
        )
        let manager = PremiumSettingsWindowManager(
            factories: factories,
            activationHandler: {}
        )

        XCTAssertTrue(calls.isEmpty)
        manager.present(.calendarMeeting)

        XCTAssertEqual(calls, [.calendarMeeting: 1])
        manager.closeAll()
    }

    func testPresentCreatesOneWindowPerDestinationAndReusesIt() {
        var factoryCalls = 0
        var activationCalls = 0
        let factories = makeFactories {
            factoryCalls += 1
            return self.definition(for: .calendarMeeting)
        }
        let manager = PremiumSettingsWindowManager(
            factories: factories,
            windowFactory: { contentRect, styleMask in
                TrackingWindow(
                    contentRect: contentRect,
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false
                )
            },
            activationHandler: { activationCalls += 1 }
        )

        manager.present(.calendarMeeting)
        let firstWindow = manager.managedWindow(for: .calendarMeeting)
        manager.present(.calendarMeeting)
        let secondWindow = manager.managedWindow(for: .calendarMeeting)

        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(firstWindow === secondWindow)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(activationCalls, 2)
        XCTAssertEqual((firstWindow as? TrackingWindow)?.frontCount, 2)

        manager.closeAll()
    }

    func testWindowUsesExpectedNativeConfigurationAndAutosaveName() throws {
        let manager = PremiumSettingsWindowManager(
            factories: makeFactories { self.definition(for: .access) },
            activationHandler: {}
        )
        defer { manager.closeAll() }

        manager.present(.access)
        let window = try XCTUnwrap(manager.managedWindow(for: .access))

        XCTAssertFalse(window is NSPanel)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CGSize(width: 500, height: 420))
        XCTAssertEqual(window.frameAutosaveName, "premium-settings.access")
        XCTAssertEqual(window.identifier?.rawValue, "premium.window.access")
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    func testClosingWindowRemovesManagedReference() throws {
        var factoryCalls = 0
        let manager = PremiumSettingsWindowManager(
            factories: makeFactories {
                factoryCalls += 1
                return self.definition(for: .cloudSync)
            },
            activationHandler: {}
        )
        defer { manager.closeAll() }

        manager.present(.cloudSync)
        let window = try XCTUnwrap(manager.managedWindow(for: .cloudSync))
        window.close()

        XCTAssertNil(manager.managedWindow(for: .cloudSync))

        manager.present(.cloudSync)
        XCTAssertEqual(factoryCalls, 2)
    }

    func testCloseAllClosesEveryDestination() {
        let manager = PremiumSettingsWindowManager(
            factories: makeFactories { self.definition(for: .access) },
            activationHandler: {}
        )

        manager.present(.access)
        manager.present(.calendarMeeting)
        manager.present(.correctionLearning)
        manager.present(.cloudSync)
        manager.closeAll()

        for destination in PremiumSettingsDestination.allCases {
            XCTAssertNil(manager.managedWindow(for: destination))
        }
    }

    private func makeFactories(
        factory: @escaping @MainActor () -> PremiumSettingsWindowDefinition
    ) -> PremiumSettingsWindowFactories {
        PremiumSettingsWindowFactories(
            access: factory,
            calendarMeeting: factory,
            correctionLearning: factory,
            cloudSync: factory
        )
    }

    private func definition(
        for destination: PremiumSettingsDestination
    ) -> PremiumSettingsWindowDefinition {
        let sizes: (CGSize, CGSize)
        switch destination {
        case .access:
            sizes = (CGSize(width: 560, height: 500), CGSize(width: 500, height: 420))
        case .calendarMeeting:
            sizes = (CGSize(width: 640, height: 700), CGSize(width: 560, height: 520))
        case .correctionLearning:
            sizes = (CGSize(width: 580, height: 560), CGSize(width: 520, height: 460))
        case .cloudSync:
            sizes = (CGSize(width: 640, height: 600), CGSize(width: 560, height: 500))
        }
        return PremiumSettingsWindowDefinition(
            title: destination.rawValue,
            preferredSize: sizes.0,
            minimumSize: sizes.1,
            accessibilityIdentifier: "premium.window.\(destination.rawValue)",
            content: AnyView(Text(destination.rawValue))
        )
    }
}

@MainActor
private final class TrackingWindow: NSWindow {
    private(set) var frontCount = 0

    override func makeKeyAndOrderFront(_ sender: Any?) {
        frontCount += 1
        super.makeKeyAndOrderFront(sender)
    }
}
