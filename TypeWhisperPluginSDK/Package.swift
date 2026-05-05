// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TypeWhisperPluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperPluginSDK", type: .dynamic, targets: ["TypeWhisperPluginSDK"]),
        .library(name: "TypeWhisperPluginSDKTesting", targets: ["TypeWhisperPluginSDKTesting"]),
    ],
    targets: [
        .target(name: "TypeWhisperPluginSDK"),
        .target(
            name: "TypeWhisperPluginSDKTesting",
            dependencies: ["TypeWhisperPluginSDK"]
        ),
        .target(
            name: "OpenAICompatiblePlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/OpenAICompatiblePlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FillerWordsPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/FillerWordsPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "ObsidianPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/ObsidianPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "SystemTTSPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/SystemTTSPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FileMemoryPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/FileMemoryPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "LiveTranscriptPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/LiveTranscriptPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .testTarget(
            name: "TypeWhisperPluginSDKTests",
            dependencies: ["TypeWhisperPluginSDK"]
        ),
        .testTarget(
            name: "OpenAICompatiblePluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "OpenAICompatiblePlugin",
            ],
            path: "Plugins/OpenAICompatiblePlugin/Tests"
        ),
        .testTarget(
            name: "FillerWordsPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "FillerWordsPlugin",
            ],
            path: "Plugins/FillerWordsPlugin/Tests"
        ),
        .testTarget(
            name: "ObsidianPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "ObsidianPlugin",
            ],
            path: "Plugins/ObsidianPlugin/Tests"
        ),
        .testTarget(
            name: "SystemTTSPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "SystemTTSPlugin",
            ],
            path: "Plugins/SystemTTSPlugin/Tests"
        ),
        .testTarget(
            name: "FileMemoryPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "FileMemoryPlugin",
            ],
            path: "Plugins/FileMemoryPlugin/Tests"
        ),
        .testTarget(
            name: "LiveTranscriptPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "LiveTranscriptPlugin",
            ],
            path: "Plugins/LiveTranscriptPlugin/Tests"
        ),
    ]
)
