// swift-tools-version: 6.0

import PackageDescription

// The interface between the app and the modules it is built with. It depends on
// neither the app nor TypeWhisperPluginSDK.
let package = Package(
    name: "TypeWhisperModuleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperModuleKit", targets: ["TypeWhisperModuleKit"]),
    ],
    targets: [
        .target(name: "TypeWhisperModuleKit"),
    ]
)
