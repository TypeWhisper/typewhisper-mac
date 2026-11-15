// swift-tools-version: 6.0

import PackageDescription

// Builds without modules. The app refers to this package through the
// Packages/TypeWhisperModules symlink, which another package with the same
// products can replace.
let package = Package(
    name: "TypeWhisperModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperModules", targets: ["TypeWhisperModules"]),
    ],
    dependencies: [
        // Resolved next to the symlink, so a replacement package uses the same path.
        .package(path: "../TypeWhisperModuleKit"),
    ],
    targets: [
        .target(
            name: "TypeWhisperModules",
            dependencies: [.product(name: "TypeWhisperModuleKit", package: "TypeWhisperModuleKit")]
        ),
    ]
)
