import Foundation
import os
import XCTest
@testable import WebLinkPlugin
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting

final class WebLinkPluginTests: XCTestCase {
    func testURLValidatorAcceptsHTTPAndHTTPSOnlyWithoutCredentials() {
        XCTAssertNotNil(WebLinkURLValidator.validatedURL(from: "https://youtu.be/example"))
        XCTAssertNotNil(WebLinkURLValidator.validatedURL(from: "http://example.com/media"))
        XCTAssertNil(WebLinkURLValidator.validatedURL(from: "file:///private/tmp/audio.m4a"))
        XCTAssertNil(WebLinkURLValidator.validatedURL(from: "javascript:alert(1)"))
        XCTAssertNil(WebLinkURLValidator.validatedURL(from: "https://user:password@example.com/video"))
        XCTAssertNil(WebLinkURLValidator.validatedURL(from: "https:///missing-host"))
    }

    func testToolLocatorUsesPATHAndRequiresExecutableFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("yt-dlp")
        let nonExecutable = root.appendingPathComponent("non-executable-test-tool")
        try Data().write(to: executable)
        try Data().write(to: nonExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)

        let locator = WebLinkToolLocator(environment: ["PATH": root.path], homeDirectory: root)

        XCTAssertEqual(locator.locate("yt-dlp"), executable)
        XCTAssertNil(locator.locate("non-executable-test-tool"))
    }

    func testDownloadRequestKeepsURLAsSingleArgumentAndDisablesUserConfiguration() throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "https://example.com/watch?v=one;touch%20/tmp/pwned")
        )
        let outputDirectory = URL(fileURLWithPath: "/private/tmp/web-link-job")
        let ffmpegURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

        let request = WebLinkDownloadRequest.make(
            ytDLPURL: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            ffmpegURL: ffmpegURL,
            sourceURL: sourceURL,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(request.executableURL.path, "/opt/homebrew/bin/yt-dlp")
        XCTAssertTrue(request.arguments.contains("--no-config"))
        XCTAssertTrue(request.arguments.contains("--no-playlist"))
        XCTAssertEqual(request.arguments.suffix(2), ["--", sourceURL.absoluteString])
        let ffmpegIndex = try XCTUnwrap(request.arguments.firstIndex(of: "--ffmpeg-location"))
        XCTAssertEqual(request.arguments[ffmpegIndex + 1], ffmpegURL.deletingLastPathComponent().path)
        XCTAssertFalse(request.arguments.contains("touch"))
    }

    func testHomebrewInstallRequestsOnlyMissingTools() async throws {
        let runner = RecordingWebLinkProcessRunner()
        let installer = WebLinkToolInstaller(runner: runner)
        let brewURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

        try await installer.install(
            missingTools: [.ffmpeg],
            homebrewURL: brewURL,
            workingDirectory: URL(fileURLWithPath: "/private/tmp")
        )

        let recordedRequests = await runner.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.executableURL, brewURL)
        XCTAssertEqual(request.arguments, ["install", "ffmpeg"])
    }

    func testProcessRunnerReportsTaskCancellationAsCancellationError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = WebLinkProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: [:],
            workingDirectory: root
        )
        let task = Task {
            try await WebLinkProcessRunner().run(request)
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the helper process to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation is not surfaced as a download failure.
        }
    }

    @MainActor
    func testProgressCancellationCancelsRunnerAndRemovesJobDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try makeToolDirectory(in: root)
        let runner = CancellationTrackingWebLinkProcessRunner()
        let plugin = WebLinkPlugin(
            runner: runner,
            environment: ["PATH": bin.path],
            homeDirectory: root
        )
        let pluginDataDirectory = root.appendingPathComponent("plugin-data", isDirectory: true)
        let host = try PluginTestHostServices(pluginDataDirectory: pluginDataDirectory)
        plugin.activate(host: host)
        let callbackCount = OSAllocatedUnfairLock(initialState: 0)

        let importTask = Task {
            try await plugin.importMedia(
                from: URL(string: "https://youtu.be/cancel-after-launch")!,
                onProgress: { _ in
                    callbackCount.withLock { count in
                        count += 1
                        return count < 2
                    }
                }
            )
        }

        let cancellationWasPolled = await waitUntil {
            callbackCount.withLock { $0 >= 2 }
        }
        if !cancellationWasPolled {
            importTask.cancel()
        }

        do {
            _ = try await importTask.value
            XCTFail("Expected progress cancellation to stop the import")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(cancellationWasPolled)
        XCTAssertTrue(runner.wasCancelled)
        let importsDirectory = pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
        let remainingJobs = (try? FileManager.default.contentsOfDirectory(
            at: importsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(remainingJobs.isEmpty)
    }

    @MainActor
    func testCancelledImportCannotClearNewerImportState() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = try makeToolDirectory(in: root)
        let runner = SequencedWebLinkProcessRunner()
        let plugin = WebLinkPlugin(
            runner: runner,
            environment: ["PATH": bin.path],
            homeDirectory: root
        )
        let pluginDataDirectory = root.appendingPathComponent("plugin-data", isDirectory: true)
        let host = try PluginTestHostServices(pluginDataDirectory: pluginDataDirectory)
        plugin.activate(host: host)
        let viewModel = WebLinkTranscriptionSidebarViewModel(plugin: plugin)

        viewModel.link = "https://example.com/first"
        viewModel.importLink()
        await runner.firstStarted.wait()

        viewModel.cancelImport()
        viewModel.link = "https://example.com/second"
        viewModel.importLink()
        await runner.secondStarted.wait()
        await runner.releaseFirst.open()

        let staleImportWasCleaned = await waitUntil {
            let importsDirectory = pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
            let jobs = (try? FileManager.default.contentsOfDirectory(
                at: importsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            return jobs.count == 1
        }
        XCTAssertTrue(staleImportWasCleaned)
        await Task.yield()

        XCTAssertTrue(viewModel.isImporting)
        XCTAssertNotNil(viewModel.progress)

        await runner.releaseSecond.open()
        let secondImportFinished = await waitUntil { !viewModel.isImporting }
        XCTAssertTrue(secondImportFinished)
        XCTAssertNotNil(viewModel.successMessage)
    }

    @MainActor
    func testPluginImportsDownloadedM4AAndReturnsCleanupToken() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["yt-dlp", "ffmpeg"] {
            let executable = bin.appendingPathComponent(name)
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let runner = RecordingWebLinkProcessRunner { request in
            let mediaURL = request.workingDirectory.appendingPathComponent("Downloaded-episode.m4a")
            try Data([0, 1, 2]).write(to: mediaURL)
            return WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
        }
        let plugin = WebLinkPlugin(
            runner: runner,
            environment: ["PATH": bin.path],
            homeDirectory: root
        )
        let host = try PluginTestHostServices(pluginDataDirectory: root.appendingPathComponent("plugin-data"))
        plugin.activate(host: host)

        let imported = try await plugin.importMedia(
            from: URL(string: "https://youtu.be/example")!,
            onProgress: { _ in true }
        )

        XCTAssertEqual(imported.localFileURL.lastPathComponent, "Downloaded-episode.m4a")
        XCTAssertEqual(imported.displayName, "Downloaded-episode")
        XCTAssertNotNil(imported.cleanupToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.localFileURL.path))

        await plugin.removeImportedMedia(imported)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.localFileURL.path))
    }

    @MainActor
    func testSidebarContributionAndMenuCommandsOpenItThroughHost() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = WebLinkPlugin(
            runner: RecordingWebLinkProcessRunner(),
            environment: [:],
            homeDirectory: root
        )
        let host = try PluginTestHostServices(pluginDataDirectory: root.appendingPathComponent("plugin-data"))
        plugin.activate(host: host)

        XCTAssertEqual(plugin.appMenuCommands.map(\.id), ["transcribe-web-link", "open-settings"])
        XCTAssertEqual(plugin.primaryMenuBarCommands.map(\.id), ["transcribe-web-link", "open-settings"])
        XCTAssertEqual(plugin.settingsSidebarItems, [
            PluginSettingsSidebarItemDescriptor(
                id: "web-link-transcription",
                title: "Web Link Transcription",
                systemImageName: "link"
            )
        ])
        XCTAssertNotNil(plugin.settingsSidebarView(for: "web-link-transcription"))

        plugin.performPluginCommand("transcribe-web-link")

        XCTAssertEqual(host.openedSettingsSidebarItemIds, ["web-link-transcription"])

        let importedMedia = PluginImportedMedia(
            localFileURL: root.appendingPathComponent("downloaded.m4a"),
            displayName: "Downloaded"
        )
        let wasEnqueued = await plugin.enqueueImportedMediaForTranscription(importedMedia)
        XCTAssertTrue(wasEnqueued)
        XCTAssertEqual(host.enqueuedImportedMedia, [importedMedia])
        XCTAssertEqual(host.enqueuedMediaImporterIds, ["web-link"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebLinkPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeToolDirectory(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["yt-dlp", "ffmpeg"] {
            let executable = bin.appendingPathComponent(name)
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return bin
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor RecordingWebLinkProcessRunner: WebLinkProcessRunning {
    private(set) var requests: [WebLinkProcessRequest] = []
    private let handler: @Sendable (WebLinkProcessRequest) throws -> WebLinkProcessResult

    init(
        handler: @escaping @Sendable (WebLinkProcessRequest) throws -> WebLinkProcessResult = { _ in
            WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
        }
    ) {
        self.handler = handler
    }

    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult {
        requests.append(request)
        return try handler(request)
    }

    func recordedRequests() -> [WebLinkProcessRequest] {
        requests
    }
}

private final class CancellationTrackingWebLinkProcessRunner: WebLinkProcessRunning, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var wasCancelled: Bool {
        state.withLock { $0 }
    }

    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult {
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
        } onCancel: {
            state.withLock { $0 = true }
        }
    }
}

private actor SequencedWebLinkProcessRunner: WebLinkProcessRunning {
    let firstStarted = WebLinkTestGate()
    let secondStarted = WebLinkTestGate()
    let releaseFirst = WebLinkTestGate()
    let releaseSecond = WebLinkTestGate()
    private var invocationCount = 0

    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult {
        invocationCount += 1
        let invocation = invocationCount
        if invocation == 1 {
            await firstStarted.open()
            await releaseFirst.wait()
        } else {
            await secondStarted.open()
            await releaseSecond.wait()
        }

        let mediaURL = request.workingDirectory.appendingPathComponent("downloaded-\(invocation).m4a")
        try Data([UInt8(invocation)]).write(to: mediaURL)
        return WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
    }
}

private actor WebLinkTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}
