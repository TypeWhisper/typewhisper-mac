@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import TypeWhisper

final class SenseVoiceRuntimeTests: XCTestCase {
    func testRuntimeSmokeTranscribesEnglishFixtureWhenEnabled() throws {
        guard Self.runtimeSmokeTestsEnabled else {
            throw XCTSkip("Set TYPEWHISPER_RUN_SENSEVOICE_RUNTIME_TESTS=1 to run the SenseVoice runtime smoke test.")
        }

        let modelDirectory = URL(fileURLWithPath: "/tmp/typewhisper-sensevoice-bench")
            .appendingPathComponent(SenseVoiceModelAssetManager.modelId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.int8.onnx").path),
              FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("tokens.txt").path) else {
            throw XCTSkip("SenseVoice smoke model is not downloaded at \(modelDirectory.path).")
        }

        let recognizer = try SenseVoiceONNXRecognizer(modelDirectory: modelDirectory, language: "en")
        let fixture = try Self.makeEnglishFixtureSamples()

        let text = try recognizer.transcribe(samples: fixture.samples, sampleRate: fixture.sampleRate)

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private static var runtimeSmokeTestsEnabled: Bool {
        if ProcessInfo.processInfo.environment["TYPEWHISPER_RUN_SENSEVOICE_RUNTIME_TESTS"] == "1" {
            return true
        }

        guard let flagURL = Bundle(for: SenseVoiceRuntimeTests.self).url(
            forResource: "SenseVoiceRuntimeTestFlag",
            withExtension: nil
        ),
              let flag = try? String(contentsOf: flagURL, encoding: .utf8) else {
            return false
        }

        return flag.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func makeEnglishFixtureSamples() throws -> (samples: [Float], sampleRate: Int) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typewhisper-sensevoice-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("english-fixture.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", audioURL.path, "hello from type whisper"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Unable to generate the local English speech fixture with /usr/bin/say.")
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        ) else {
            throw SenseVoicePluginError.transcriptionFailed("Failed to allocate the input fixture buffer.")
        }
        try audioFile.read(into: inputBuffer)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
              let converter = AVAudioConverter(from: audioFile.processingFormat, to: outputFormat) else {
            throw SenseVoicePluginError.transcriptionFailed("Failed to create the fixture audio converter.")
        }

        let capacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / audioFile.processingFormat.sampleRate)
        ) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SenseVoicePluginError.transcriptionFailed("Failed to allocate the output fixture buffer.")
        }

        var conversionError: NSError?
        let inputProvider = SenseVoiceFixtureInputProvider(buffer: inputBuffer)
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(status: outStatus)
        }

        if status == .error {
            throw conversionError ?? SenseVoicePluginError.transcriptionFailed("Failed to convert the fixture audio.")
        }

        guard let channel = outputBuffer.floatChannelData?[0] else {
            throw SenseVoicePluginError.transcriptionFailed("Converted fixture audio has no float channel.")
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        return (samples, 16_000)
    }
}

private final class SenseVoiceFixtureInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideInput {
            status.pointee = .endOfStream
            return nil
        }

        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
