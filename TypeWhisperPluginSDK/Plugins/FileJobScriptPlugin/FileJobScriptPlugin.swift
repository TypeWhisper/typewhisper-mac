import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

@objc(FileJobScriptPlugin)
final class FileJobScriptPlugin: NSObject, FileJobAutomationPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.file-job-script"
    static let pluginName = "File Job Script"

    let automationName = "File Job Script"
    let priority = 400

    private var service: FileJobScriptService?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        service = FileJobScriptService(dataDirectory: host.pluginDataDirectory)
    }

    func deactivate() {
        service = nil
    }

    @MainActor
    var settingsView: AnyView? {
        guard let service else { return nil }
        return AnyView(FileJobScriptSettingsView(service: service))
    }

    @MainActor
    func process(artifact: FileJobArtifact, context: FileJobContext) async throws -> FileJobAutomationResult {
        guard let service else { return FileJobAutomationResult(artifact: artifact) }
        return await service.process(artifact: artifact, context: context)
    }
}

struct FileJobScriptConfig: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var command: String
    var isEnabled: Bool
    var timeoutSeconds: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        command: String,
        isEnabled: Bool = true,
        timeoutSeconds: Int = 120
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.isEnabled = isEnabled
        self.timeoutSeconds = timeoutSeconds
    }

    var effectiveTimeoutSeconds: Int {
        min(max(timeoutSeconds, 5), 3_600)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Script" : trimmed
    }
}

struct FileJobScriptExecutionResult: Equatable, Sendable {
    let artifact: FileJobArtifact
    let didChangeArtifact: Bool
    let wroteOutputPath: Bool
    let errorMessage: String?
    let durationMs: Int
}

struct FileJobScriptExecutionLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let scriptName: String
    let success: Bool
    let durationMs: Int
    let errorMessage: String?
}

final class FileJobScriptService: ObservableObject, @unchecked Sendable {
    @Published var scripts: [FileJobScriptConfig] = []
    @Published var executionLog: [FileJobScriptExecutionLogEntry] = []

    private let configURL: URL
    private let runner: FileJobScriptRunner
    private let maxLogEntries = 20

    init(dataDirectory: URL, runner: FileJobScriptRunner = FileJobScriptRunner()) {
        self.configURL = dataDirectory.appendingPathComponent("file-job-scripts.json")
        self.runner = runner
        loadConfig()
    }

    func addScript(_ script: FileJobScriptConfig) {
        scripts.append(script)
        saveConfig()
    }

    func removeScript(id: UUID) {
        scripts.removeAll { $0.id == id }
        saveConfig()
    }

    func updateScript(_ script: FileJobScriptConfig) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        saveConfig()
    }

    func process(artifact: FileJobArtifact, context: FileJobContext) async -> FileJobAutomationResult {
        var currentArtifact = artifact
        var appliedSteps: [String] = []
        var outputPathWasWritten = false

        for script in scripts where script.isEnabled {
            let result = await runner.execute(script: script, artifact: currentArtifact, context: context)
            addLog(FileJobScriptExecutionLogEntry(
                scriptName: script.displayName,
                success: result.errorMessage == nil,
                durationMs: result.durationMs,
                errorMessage: result.errorMessage
            ))

            guard result.errorMessage == nil, result.didChangeArtifact else { continue }
            currentArtifact = result.artifact
            outputPathWasWritten = outputPathWasWritten || result.wroteOutputPath
            appliedSteps.append(script.displayName)
        }

        return FileJobAutomationResult(
            artifact: currentArtifact,
            appliedSteps: appliedSteps,
            outputPathWasWritten: outputPathWasWritten
        )
    }

    func saveConfig() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: configURL, options: .atomic)
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode([FileJobScriptConfig].self, from: data) else { return }
        scripts = config
    }

    private func addLog(_ entry: FileJobScriptExecutionLogEntry) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.executionLog.insert(entry, at: 0)
            if self.executionLog.count > self.maxLogEntries {
                self.executionLog = Array(self.executionLog.prefix(self.maxLogEntries))
            }
        }
    }
}

final class FileJobScriptRunner: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func execute(
        script: FileJobScriptConfig,
        artifact: FileJobArtifact,
        context: FileJobContext
    ) async -> FileJobScriptExecutionResult {
        let start = Date()

        do {
            let sidecarDirectory = try makeSidecarDirectory()
            defer { try? fileManager.removeItem(at: sidecarDirectory) }

            let sidecars = try FileJobScriptSidecarWriter.write(context: context, to: sidecarDirectory)
            let outputSnapshot = OutputFileSnapshot.capture(path: context.outputFilePath, fileManager: fileManager)
            let stdout = try await runProcess(
                command: script.command,
                input: artifact.content,
                context: context,
                sidecars: sidecars,
                timeoutSeconds: script.effectiveTimeoutSeconds
            )

            if !stdout.isEmpty {
                return FileJobScriptExecutionResult(
                    artifact: FileJobArtifact(fileExtension: artifact.fileExtension, content: stdout),
                    didChangeArtifact: stdout != artifact.content,
                    wroteOutputPath: false,
                    errorMessage: nil,
                    durationMs: elapsedMilliseconds(since: start)
                )
            }

            if let outputPath = context.outputFilePath,
               OutputFileSnapshot.pathDidChange(outputPath, comparedTo: outputSnapshot, fileManager: fileManager),
               let replacement = try? String(contentsOfFile: outputPath, encoding: .utf8) {
                return FileJobScriptExecutionResult(
                    artifact: FileJobArtifact(fileExtension: artifact.fileExtension, content: replacement),
                    didChangeArtifact: replacement != artifact.content,
                    wroteOutputPath: true,
                    errorMessage: nil,
                    durationMs: elapsedMilliseconds(since: start)
                )
            }

            return FileJobScriptExecutionResult(
                artifact: artifact,
                didChangeArtifact: false,
                wroteOutputPath: false,
                errorMessage: FileJobScriptError.emptyOutput.errorDescription,
                durationMs: elapsedMilliseconds(since: start)
            )
        } catch {
            return FileJobScriptExecutionResult(
                artifact: artifact,
                didChangeArtifact: false,
                wroteOutputPath: false,
                errorMessage: error.localizedDescription,
                durationMs: elapsedMilliseconds(since: start)
            )
        }
    }

    private func makeSidecarDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("typewhisper-file-job-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }

    private func runProcess(
        command: String,
        input: String,
        context: FileJobContext,
        sidecars: FileJobScriptSidecarPaths,
        timeoutSeconds: Int
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.environment = FileJobScriptEnvironmentBuilder.environment(
                    context: context,
                    sidecars: sidecars
                )

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdoutData = OSAllocatedUnfairLock(initialState: Data())
                let stderrData = OSAllocatedUnfairLock(initialState: Data())
                let didTimeout = OSAllocatedUnfairLock(initialState: false)

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutData.withLock { $0.append(handle.availableData) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrData.withLock { $0.append(handle.availableData) }
                }

                let timeoutWork = DispatchWorkItem { [weak process] in
                    didTimeout.withLock { $0 = true }
                    process?.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWork)

                do {
                    try process.run()

                    let inputData = input.data(using: .utf8) ?? Data()
                    stdinPipe.fileHandleForWriting.write(inputData)
                    stdinPipe.fileHandleForWriting.closeFile()

                    process.waitUntilExit()
                    timeoutWork.cancel()

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    stdoutData.withLock {
                        $0.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    stderrData.withLock {
                        $0.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    }

                    if didTimeout.withLock({ $0 }) {
                        continuation.resume(throwing: FileJobScriptError.timeout(seconds: timeoutSeconds))
                        return
                    }

                    guard process.terminationStatus == 0 else {
                        let stderr = stderrData.withLock {
                            String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        continuation.resume(throwing: FileJobScriptError.nonZeroExit(
                            code: process.terminationStatus,
                            stderr: stderr
                        ))
                        return
                    }

                    let outputData = stdoutData.withLock { $0 }
                    var output = String(data: outputData, encoding: .utf8) ?? ""
                    if output.hasSuffix("\n") {
                        output = String(output.dropLast())
                    }
                    output = output.replacingOccurrences(of: "\0", with: "")
                    continuation.resume(returning: output)
                } catch {
                    timeoutWork.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct FileJobScriptSidecarPaths: Sendable {
    let transcriptJSONPath: String
    let segmentsJSONPath: String
}

enum FileJobScriptSidecarWriter {
    private struct TranscriptPayload: Encodable {
        let text: String
        let detected_language: String?
        let engine_id: String?
        let engine_name: String?
        let model_id: String?
        let segments: [FileJobTranscriptSegment]
    }

    static func write(context: FileJobContext, to directory: URL) throws -> FileJobScriptSidecarPaths {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let segmentsURL = directory.appendingPathComponent("segments.json")
        let transcriptPayload = TranscriptPayload(
            text: context.transcriptText,
            detected_language: context.detectedLanguage,
            engine_id: context.engineId,
            engine_name: context.engineName,
            model_id: context.modelId,
            segments: context.segments
        )

        try encoder.encode(transcriptPayload).write(to: transcriptURL, options: .atomic)
        try encoder.encode(context.segments).write(to: segmentsURL, options: .atomic)

        return FileJobScriptSidecarPaths(
            transcriptJSONPath: transcriptURL.path,
            segmentsJSONPath: segmentsURL.path
        )
    }
}

enum FileJobScriptEnvironmentBuilder {
    static func environment(
        context: FileJobContext,
        sidecars: FileJobScriptSidecarPaths,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        if env["LANG"] == nil && env["LC_ALL"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }

        env["TYPEWHISPER_JOB_KIND"] = context.jobKind.rawValue
        env["TYPEWHISPER_TRANSCRIPT_TEXT"] = context.transcriptText
        env["TYPEWHISPER_TRANSCRIPT_JSON_PATH"] = sidecars.transcriptJSONPath
        env["TYPEWHISPER_SEGMENTS_JSON_PATH"] = sidecars.segmentsJSONPath

        setIfPresent(context.sourceFilePath, forKey: "TYPEWHISPER_SOURCE_FILE_PATH", in: &env)
        setIfPresent(context.sourceFileName, forKey: "TYPEWHISPER_SOURCE_FILE_NAME", in: &env)
        setIfPresent(context.outputDirectoryPath, forKey: "TYPEWHISPER_OUTPUT_DIR", in: &env)
        setIfPresent(context.outputFilePath, forKey: "TYPEWHISPER_OUTPUT_PATH", in: &env)
        setIfPresent(context.outputFormat, forKey: "TYPEWHISPER_OUTPUT_FORMAT", in: &env)
        setIfPresent(context.engineId, forKey: "TYPEWHISPER_ENGINE_ID", in: &env)
        setIfPresent(context.engineName, forKey: "TYPEWHISPER_ENGINE_NAME", in: &env)
        setIfPresent(context.modelId, forKey: "TYPEWHISPER_MODEL_ID", in: &env)
        setIfPresent(context.detectedLanguage, forKey: "TYPEWHISPER_LANGUAGE", in: &env)

        return env
    }

    private static func setIfPresent(_ value: String?, forKey key: String, in env: inout [String: String]) {
        guard let value, !value.isEmpty else { return }
        env[key] = value
    }
}

private struct OutputFileSnapshot: Equatable {
    let exists: Bool
    let modificationDate: Date?
    let fileSize: UInt64?

    static func capture(path: String?, fileManager: FileManager) -> OutputFileSnapshot {
        guard let path else {
            return OutputFileSnapshot(exists: false, modificationDate: nil, fileSize: nil)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return OutputFileSnapshot(exists: false, modificationDate: nil, fileSize: nil)
        }

        return OutputFileSnapshot(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: attributes[.size] as? UInt64
        )
    }

    static func pathDidChange(_ path: String, comparedTo snapshot: OutputFileSnapshot, fileManager: FileManager) -> Bool {
        let current = capture(path: path, fileManager: fileManager)
        guard current.exists else { return false }
        return current != snapshot
    }
}

enum FileJobScriptError: LocalizedError, Equatable {
    case timeout(seconds: Int)
    case nonZeroExit(code: Int32, stderr: String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Script timed out after \(seconds) seconds"
        case .nonZeroExit(let code, let stderr):
            return "Exit code \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .emptyOutput:
            return "Script produced no output"
        }
    }
}

private struct FileJobScriptSettingsView: View {
    @ObservedObject var service: FileJobScriptService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File Job Script")
                    .font(.headline)
                Spacer()
                Button {
                    service.addScript(FileJobScriptConfig(
                        name: "New Script",
                        command: #"cat > "$TYPEWHISPER_OUTPUT_PATH""#
                    ))
                } label: {
                    Label(String(localized: "Add Script"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if service.scripts.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Scripts"),
                    systemImage: "terminal",
                    description: Text(String(localized: "Add a script to customize watch-folder exports."))
                )
            } else {
                List {
                    ForEach($service.scripts) { $script in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle(String(localized: "Enabled"), isOn: $script.isEnabled)
                                Spacer()
                                Button(role: .destructive) {
                                    service.removeScript(id: script.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }

                            TextField(String(localized: "Name"), text: $script.name)
                            TextField(String(localized: "Command"), text: $script.command, axis: .vertical)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(3...8)
                            Stepper(
                                String(localized: "Timeout: \(script.effectiveTimeoutSeconds)s"),
                                value: $script.timeoutSeconds,
                                in: 5...3_600,
                                step: 5
                            )
                        }
                        .padding(.vertical, 6)
                        .onChange(of: script) { _, _ in
                            service.saveConfig()
                        }
                    }
                }
                .listStyle(.inset)
            }

            if !service.executionLog.isEmpty {
                Divider()
                Text(String(localized: "Recent Runs"))
                    .font(.subheadline.weight(.semibold))
                ForEach(service.executionLog.prefix(5)) { entry in
                    Label(
                        entry.errorMessage ?? "\(entry.scriptName) finished in \(entry.durationMs)ms",
                        systemImage: entry.success ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundStyle(entry.success ? Color.secondary : Color.red)
                    .font(.caption)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }
}
