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
        let precisions = (ProcessInfo.processInfo.environment["DICTUM_SPEECH_BENCHMARK_PRECISIONS"] ?? "8bit,6bit")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for round in 0..<6 {
            for precision in round.isMultiple(of: 2) ? precisions : Array(precisions.reversed()) {
                plugin.unloadModel()
                await plugin.runtimeCacheClearTask?.value
                Memory.peakMemory = 0
                let loadStart = Date()
                plugin.triggerRestoreModel(forModel: "qwen3-asr-1.7b-\(precision)" as NSString)
                await plugin.explicitModelLoadTask?.value
                let loadSeconds = Date().timeIntervalSince(loadStart)
                XCTAssertTrue(plugin.isConfigured, plugin.currentSettingsActivity?.message ?? "Model unavailable")
                guard plugin.isConfigured else { return }
                for name in ["zh", "en", "mixed", "zh30", "regression"] {
                    let file = try AVAudioFile(forReading: root.appendingPathComponent("\(name).wav"))
                    XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
                    XCTAssertEqual(file.processingFormat.channelCount, 1)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                    try file.read(into: buffer)
                    let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
                    let duration = Double(samples.count) / 16_000
                    let start = Date()
                    var cpuBefore = rusage()
                    getrusage(RUSAGE_SELF, &cpuBefore)
                    let result = try await plugin.transcribe(audio: AudioData(samples: samples, wavData: Data(), duration: duration), language: nil, translate: false, prompt: nil)
                    let elapsed = Date().timeIntervalSince(start)
                    var cpuAfter = rusage()
                    getrusage(RUSAGE_SELF, &cpuAfter)
                    let cpuSeconds = Double(cpuAfter.ru_utime.tv_sec - cpuBefore.ru_utime.tv_sec)
                        + Double(cpuAfter.ru_utime.tv_usec - cpuBefore.ru_utime.tv_usec) / 1_000_000
                        + Double(cpuAfter.ru_stime.tv_sec - cpuBefore.ru_stime.tv_sec)
                        + Double(cpuAfter.ru_stime.tv_usec - cpuBefore.ru_stime.tv_usec) / 1_000_000
                    XCTAssertFalse(result.text.isEmpty)
                    rows.append(["round": round, "precision": precision, "clip": name, "loadSeconds": loadSeconds,
                                 "inferenceSeconds": elapsed, "duration": duration, "realTimeFactor": elapsed / duration,
                                 "cpuSeconds": cpuSeconds, "processPeakRSSBytes": cpuAfter.ru_maxrss,
                                 "peakMLXBytes": Memory.peakMemory, "transcript": result.text])
                    print("SPEECH_BENCHMARK round=\(round) precision=\(precision) clip=\(name) load=\(loadSeconds) seconds=\(elapsed) rtf=\(elapsed / duration) cpu=\(cpuSeconds) rss=\(cpuAfter.ru_maxrss) mlxPeak=\(Memory.peakMemory) text=\(result.text)")
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("release-benchmark.json"), options: .atomic)
                }
            }
        }
    }
}
