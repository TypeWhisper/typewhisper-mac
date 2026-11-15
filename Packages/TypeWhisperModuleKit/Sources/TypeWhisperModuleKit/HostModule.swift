/// A module the app is built with.
///
/// The app creates its modules once at launch, hands each one a `ModuleHost`
/// and adds the returned contributions to its own interface.
@MainActor
public protocol HostModule: AnyObject {
    /// Stable reverse-DNS identifier, used in logs and diagnostics.
    var identifier: String { get }

    /// What the module adds to the app. Called once, at launch.
    func contributions(for host: any ModuleHost) -> ModuleContributions
}

/// The entry point of a `TypeWhisperModules` package.
///
/// Every package with the product `TypeWhisperModules` exposes one type named
/// `ModuleEntry` that conforms to this protocol. The app calls it directly.
public protocol ModuleEntryPoint {
    /// True for the stub package, which contains no modules.
    static var isStub: Bool { get }

    /// The interface version the modules were written against. The app loads
    /// no modules when `ModuleKitVersion.current` does not support it.
    static var requiredModuleKitVersion: ModuleKitVersion { get }

    /// Creates the modules in this package.
    @MainActor static func makeModules() -> [any HostModule]
}
