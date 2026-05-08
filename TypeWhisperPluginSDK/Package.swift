// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TypeWhisperPluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperPluginSDK", type: .dynamic, targets: ["TypeWhisperPluginSDK"]),
        .library(name: "TypeWhisperPluginSDKTesting", targets: ["TypeWhisperPluginSDKTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "2685c640d4079641a01ef3489cacb684c34109fd"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
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
            name: "OpenAIPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/OpenAIPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "Qwen3Plugin",
            dependencies: [
                "TypeWhisperPluginSDK",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            ],
            path: "Plugins/Qwen3Plugin",
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
        .target(
            name: "AssemblyAIPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/AssemblyAIPlugin",
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
            name: "OpenAIPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "OpenAIPlugin",
            ],
            path: "Plugins/OpenAIPlugin/Tests"
        ),
        .testTarget(
            name: "Qwen3PluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "Qwen3Plugin",
            ],
            path: "Plugins/Qwen3Plugin/Tests"
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
        .testTarget(
            name: "AssemblyAIPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "AssemblyAIPlugin",
            ],
            path: "Plugins/AssemblyAIPlugin/Tests"
        ),
    ]
)
