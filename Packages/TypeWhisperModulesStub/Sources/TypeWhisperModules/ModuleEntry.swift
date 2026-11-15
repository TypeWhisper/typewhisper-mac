import TypeWhisperModuleKit

/// The stub entry point: no modules.
public enum ModuleEntry: ModuleEntryPoint {
    public static let isStub = true
    public static let requiredModuleKitVersion = ModuleKitVersion.current

    @MainActor public static func makeModules() -> [any HostModule] { [] }
}
