/// Version of the interface in this package.
///
/// A change that existing modules can still use raises `minor`. A change that
/// breaks them raises `major` and sets `minor` to 0.
public struct ModuleKitVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// The version this package provides.
    public static let current = ModuleKitVersion(major: 1, minor: 0)

    /// Whether a module that requires `required` can run against this version.
    public func supports(_ required: ModuleKitVersion) -> Bool {
        major == required.major && minor >= required.minor
    }

    public static func < (lhs: ModuleKitVersion, rhs: ModuleKitVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}
