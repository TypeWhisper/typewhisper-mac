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
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "2685c640d4079641a01ef3489cacb684c34109fd"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.3"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.24.2"),
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
            name: "OpenRouterPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/OpenRouterPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "GroqPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/GroqPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "GeminiPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/GeminiPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "CerebrasPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/CerebrasPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "FireworksPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/FireworksPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "ClaudePlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/ClaudePlugin",
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
            name: "ParakeetPlugin",
            dependencies: [
                "TypeWhisperPluginSDK",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Plugins/ParakeetPlugin",
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
            name: "FileJobScriptPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/FileJobScriptPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "LinearPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/LinearPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
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
            name: "SupertonicPlugin",
            dependencies: [
                "TypeWhisperPluginSDK",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Plugins/SupertonicPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
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
            name: "SonioxPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/SonioxPlugin",
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
        .target(
            name: "Reson8Plugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/Reson8Plugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "SmallestAIPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/SmallestAIPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
                .process("smallest.svg"),
            ]
        ),
        .target(
            name: "SaluteSpeechPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/SaluteSpeechPlugin",
            exclude: ["Tests"],
            resources: [
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "CartesiaPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/CartesiaPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "WebhookPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/WebhookPlugin",
            exclude: ["Tests"],
            resources: [
                .process("Localizable.xcstrings"),
                .process("manifest.json"),
            ]
        ),
        .target(
            name: "MistralAIPlugin",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/MistralAIPlugin",
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
            name: "OpenRouterPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "OpenRouterPlugin",
            ],
            path: "Plugins/OpenRouterPlugin/Tests"
        ),
        .testTarget(
            name: "GroqPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "GroqPlugin",
            ],
            path: "Plugins/GroqPlugin/Tests"
        ),
        .testTarget(
            name: "GeminiPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "GeminiPlugin",
            ],
            path: "Plugins/GeminiPlugin/Tests"
        ),
        .testTarget(
            name: "CerebrasPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "CerebrasPlugin",
            ],
            path: "Plugins/CerebrasPlugin/Tests"
        ),
        .testTarget(
            name: "FireworksPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "FireworksPlugin",
            ],
            path: "Plugins/FireworksPlugin/Tests"
        ),
        .testTarget(
            name: "ClaudePluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "ClaudePlugin",
            ],
            path: "Plugins/ClaudePlugin/Tests"
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
            name: "ParakeetPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "ParakeetPlugin",
            ],
            path: "Plugins/ParakeetPlugin/Tests"
        ),
        .testTarget(
            name: "SpeechAnalyzerPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
            ],
            path: "Plugins/SpeechAnalyzerPlugin/Tests"
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
            name: "FileJobScriptPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "FileJobScriptPlugin",
            ],
            path: "Plugins/FileJobScriptPlugin/Tests"
        ),
        .testTarget(
            name: "LinearPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "LinearPlugin",
            ],
            path: "Plugins/LinearPlugin/Tests"
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
            name: "SupertonicPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "SupertonicPlugin",
            ],
            path: "Plugins/SupertonicPlugin/Tests"
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
            name: "SonioxPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "SonioxPlugin",
            ],
            path: "Plugins/SonioxPlugin/Tests"
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
        .testTarget(
            name: "Reson8PluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "Reson8Plugin",
            ],
            path: "Plugins/Reson8Plugin/Tests"
        ),
        .testTarget(
            name: "SmallestAIPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "SmallestAIPlugin",
            ],
            path: "Plugins/SmallestAIPlugin/Tests"
        ),
        .testTarget(
            name: "SaluteSpeechPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "SaluteSpeechPlugin",
            ],
            path: "Plugins/SaluteSpeechPlugin/Tests"
        ),
        .testTarget(
            name: "CartesiaPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "CartesiaPlugin",
            ],
            path: "Plugins/CartesiaPlugin/Tests"
        ),
        .testTarget(
            name: "WebhookPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "WebhookPlugin",
            ],
            path: "Plugins/WebhookPlugin/Tests"
        ),
        .testTarget(
            name: "MistralAIPluginTests",
            dependencies: [
                "TypeWhisperPluginSDK",
                "TypeWhisperPluginSDKTesting",
                "MistralAIPlugin",
            ],
            path: "Plugins/MistralAIPlugin/Tests"
        ),
    ]
)
