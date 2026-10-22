// swift-tools-version: 6.2

import PackageDescription

let providerPlugins = [
    "OpenAICompatiblePlugin", "OpenAIPlugin", "OpenRouterPlugin", "GroqPlugin",
    "GeminiPlugin", "ClaudePlugin", "SonioxPlugin", "AssemblyAIPlugin", "ElevenLabsPlugin",
]

let package = Package(
    name: "TypeWhisperPluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypeWhisperPluginSDK", type: .dynamic, targets: ["TypeWhisperPluginSDK"]),
        .library(name: "TypeWhisperPluginSDKTesting", targets: ["TypeWhisperPluginSDKTesting"]),
        .library(name: "TypeWhisperFluidAudio", targets: ["TypeWhisperFluidAudio"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.10.1"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.5.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.6"),
    ],
    targets: [
        .target(name: "TypeWhisperPluginSDK"),
        .target(name: "TypeWhisperPluginSDKTesting", dependencies: ["TypeWhisperPluginSDK"]),
        .target(
            name: "TypeWhisperFluidAudio",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
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
            resources: [.process("Localizable.xcstrings"), .process("manifest.json")]
        ),
        .target(
            name: "SpeakerDiarizationPlugin",
            dependencies: ["TypeWhisperPluginSDK", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Plugins/SpeakerDiarizationPlugin",
            exclude: ["Tests"],
            resources: [.process("manifest.json")]
        ),
        .testTarget(name: "TypeWhisperPluginSDKTests", dependencies: ["TypeWhisperPluginSDK"]),
        .testTarget(
            name: "SpeechAnalyzerPluginTests",
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/SpeechAnalyzerPlugin/Tests"
        ),
    ] + providerPlugins.map { name in
        .target(
            name: name,
            dependencies: ["TypeWhisperPluginSDK"],
            path: "Plugins/\(name)",
            exclude: name == "OpenAICompatiblePlugin" ? ["README.md", "Tests"] : ["Tests"],
            resources: [.process("Localizable.xcstrings"), .process("manifest.json")]
        )
    } + (providerPlugins + ["Qwen3Plugin", "SpeakerDiarizationPlugin"]).map { name in
        .testTarget(
            name: "\(name)Tests",
            dependencies: ["TypeWhisperPluginSDK", "TypeWhisperPluginSDKTesting", .byName(name: name)],
            path: "Plugins/\(name)/Tests"
        )
    }
)
