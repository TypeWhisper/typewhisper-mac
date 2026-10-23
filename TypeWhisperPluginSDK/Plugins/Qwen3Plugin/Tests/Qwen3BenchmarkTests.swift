import AVFoundation
import MLX
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import Qwen3Plugin

final class Qwen3BenchmarkTests: XCTestCase {
    func testRecordedSpeechBenchmark() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DICTUM_QWEN_BENCHMARK"] else {
            throw XCTSkip("Set DICTUM_QWEN_BENCHMARK to a folder containing zh.wav, en.wav and mixed.wav (16 kHz mono).")
        }
        let root = URL(fileURLWithPath: directory)
        let cache = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        try FileManager.default.createSymbolicLink(at: host.pluginDataDirectory.appendingPathComponent("models"), withDestinationURL: cache)
        let plugin = Qwen3Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        var rows: [[String: Any]] = []
        for round in 0..<6 {
            for precision in round.isMultiple(of: 2) ? ["8bit", "bf16"] : ["bf16", "8bit"] {
                plugin.unloadModel()
                await plugin.runtimeCacheClearTask?.value
                Memory.peakMemory = 0
                let start = Date()
                plugin.triggerRestoreModel(forModel: "qwen3-asr-1.7b-\(precision)" as NSString)
                await plugin.explicitModelLoadTask?.value
                let loadSeconds = Date().timeIntervalSince(start)
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
                    let inferenceStart = Date()
                    var cpuBefore = rusage()
                    getrusage(RUSAGE_SELF, &cpuBefore)
                    let result = try await plugin.transcribe(audio: AudioData(samples: samples, wavData: Data(), duration: duration), language: nil, translate: false, prompt: nil)
                    let seconds = Date().timeIntervalSince(inferenceStart)
                    var cpuAfter = rusage()
                    getrusage(RUSAGE_SELF, &cpuAfter)
                    let cpuSeconds = Double(cpuAfter.ru_utime.tv_sec - cpuBefore.ru_utime.tv_sec)
                        + Double(cpuAfter.ru_utime.tv_usec - cpuBefore.ru_utime.tv_usec) / 1_000_000
                        + Double(cpuAfter.ru_stime.tv_sec - cpuBefore.ru_stime.tv_sec)
                        + Double(cpuAfter.ru_stime.tv_usec - cpuBefore.ru_stime.tv_usec) / 1_000_000
                    XCTAssertFalse(result.text.isEmpty)
                    let row: [String: Any] = ["round": round, "precision": precision, "clip": name,
                        "loadSeconds": loadSeconds, "inferenceSeconds": seconds, "duration": duration,
                        "realTimeFactor": seconds / duration, "transcript": result.text, "cpuSeconds": cpuSeconds,
                        "processPeakRSSBytes": cpuAfter.ru_maxrss,
                        "peakMLXBytes": plugin.runtimeMemorySnapshot?.peakMemoryBytes ?? 0]
                    rows.append(row)
                    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: root.appendingPathComponent("benchmark.json"), options: .atomic)
                    print("QWEN_BENCHMARK \(precision) round=\(round) clip=\(name) seconds=\(seconds) text=\(result.text)")
                }
            }
        }
    }
}
