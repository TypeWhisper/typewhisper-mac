import AVFoundation
import MLX
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class SpeechBenchmarkTests: XCTestCase {
    func testReleaseRecordedSpeech() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DICTUM_SPEECH_BENCHMARK"] else {
            throw XCTSkip("Set TEST_RUNNER_DICTUM_SPEECH_BENCHMARK, DICTUM_VERIFY_CONFIGURATION=Release and XCODE_XCCONFIG_FILE=TypeWhisperTests/Dictum/Speech/Benchmark.xcconfig when invoking dictum-verify.sh test.")
        }
        let root = URL(fileURLWithPath: directory)
        let plugin = Qwen3Plugin()
        let host = NoticeHost(directory: root)
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        var rows: [[String: Any]] = []
        for round in 0..<6 {
            for precision in round.isMultiple(of: 2) ? ["bf16", "8bit"] : ["8bit", "bf16"] {
                plugin.unloadModel()
                await plugin.runtimeCacheClearTask?.value
                Memory.peakMemory = 0
                let loadStart = Date()
                plugin.triggerRestoreModel(forModel: "qwen3-asr-1.7b-\(precision)" as NSString)
                await plugin.explicitModelLoadTask?.value
                let loadSeconds = Date().timeIntervalSince(loadStart)
                XCTAssertTrue(plugin.isConfigured, plugin.currentSettingsActivity?.message ?? "Model unavailable")
                guard plugin.isConfigured else { return }
                for name in ["zh", "en", "mixed", "zh30"] {
                    let file = try AVAudioFile(forReading: root.appendingPathComponent("\(name).wav"))
                    XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
                    XCTAssertEqual(file.processingFormat.channelCount, 1)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                    try file.read(into: buffer)
                    let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
                    let duration = Double(samples.count) / 16_000
                    let start = Date()
                    let result = try await plugin.transcribe(audio: AudioData(samples: samples, wavData: Data(), duration: duration), language: nil, translate: false, prompt: nil)
                    let elapsed = Date().timeIntervalSince(start)
                    XCTAssertFalse(result.text.isEmpty)
                    rows.append(["round": round, "precision": precision, "clip": name, "loadSeconds": loadSeconds,
                                 "inferenceSeconds": elapsed, "duration": duration, "realTimeFactor": elapsed / duration,
                                 "peakMLXBytes": Memory.peakMemory, "transcript": result.text])
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("release-benchmark.json"), options: .atomic)
                }
            }
        }
    }
}
