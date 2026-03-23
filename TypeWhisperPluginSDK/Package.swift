// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TypeWhisperPluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperPluginSDK", type: .dynamic, targets: ["TypeWhisperPluginSDK"]),
    ],
    targets: [
        .target(name: "TypeWhisperPluginSDK"),
        .testTarget(
            name: "TypeWhisperPluginSDKTests",
            dependencies: ["TypeWhisperPluginSDK"]
        ),
    ]
)
