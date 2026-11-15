import TypeWhisperModuleKit
import XCTest
@testable import TypeWhisper

@MainActor
final class ModuleRegistryTests: XCTestCase {
    func testStubBuildLoadsNoModules() {
        let registry = ModuleRegistry(host: AppModuleHost())

        XCTAssertTrue(registry.isStub)
        XCTAssertTrue(registry.modules.isEmpty)
        XCTAssertTrue(registry.contributions.isEmpty)
    }

    func testCollectsContributionsOfEveryModule() {
        let registry = ModuleRegistry(entry: TwoModulesEntry.self, host: AppModuleHost())

        XCTAssertFalse(registry.isStub)
        XCTAssertEqual(registry.modules.map(\.identifier), ["test.first", "test.second"])
        XCTAssertEqual(registry.contributions.menuItems.map(\.id), ["test.first.menu", "test.second.menu"])
        XCTAssertEqual(registry.contributions.managedPolicyKeys.map(\.name), ["TestKey"])
    }

    func testSkipsModulesThatNeedANewerInterface() {
        let current = ModuleKitVersion.current
        let registry = ModuleRegistry(
            entry: TwoModulesEntry.self,
            host: AppModuleHost(),
            kitVersion: ModuleKitVersion(major: current.major, minor: current.minor + 1)
        )
        let newer = ModuleRegistry(
            entry: TwoModulesEntry.self,
            host: AppModuleHost(),
            kitVersion: ModuleKitVersion(major: current.major + 1, minor: 0)
        )
        TwoModulesEntry.required = ModuleKitVersion(major: current.major, minor: current.minor + 1)
        defer { TwoModulesEntry.required = .current }
        let older = ModuleRegistry(
            entry: TwoModulesEntry.self,
            host: AppModuleHost(),
            kitVersion: current
        )

        XCTAssertEqual(registry.modules.count, 2)
        XCTAssertTrue(newer.modules.isEmpty)
        XCTAssertTrue(older.modules.isEmpty)
        XCTAssertTrue(older.contributions.isEmpty)
        XCTAssertFalse(older.isStub)
    }
}

private enum TwoModulesEntry: ModuleEntryPoint {
    nonisolated(unsafe) static var required = ModuleKitVersion.current

    static var isStub: Bool { false }
    static var requiredModuleKitVersion: ModuleKitVersion { required }

    static func makeModules() -> [any HostModule] {
        [
            TestModule(identifier: "test.first", policyKeys: [ModuleManagedPolicyKey(name: "TestKey", kind: .boolean)]),
            TestModule(identifier: "test.second", policyKeys: []),
        ]
    }
}

private final class TestModule: HostModule {
    let identifier: String
    private let policyKeys: [ModuleManagedPolicyKey]

    init(identifier: String, policyKeys: [ModuleManagedPolicyKey]) {
        self.identifier = identifier
        self.policyKeys = policyKeys
    }

    func contributions(for host: any ModuleHost) -> ModuleContributions {
        ModuleContributions(
            menuItems: [ModuleMenuItem(id: "\(identifier).menu", title: identifier) {}],
            managedPolicyKeys: policyKeys
        )
    }
}
