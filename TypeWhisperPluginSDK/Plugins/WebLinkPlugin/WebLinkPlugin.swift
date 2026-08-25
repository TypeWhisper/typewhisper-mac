import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

enum WebLinkTool: String, CaseIterable, Sendable {
    case ytDLP = "yt-dlp"
    case ffmpeg

    var formula: String { rawValue }
}

struct WebLinkToolchain: Sendable, Equatable {
    let ytDLPURL: URL?
    let ffmpegURL: URL?
    let homebrewURL: URL?

    var missingTools: [WebLinkTool] {
        var result: [WebLinkTool] = []
        if ytDLPURL == nil { result.append(.ytDLP) }
        if ffmpegURL == nil { result.append(.ffmpeg) }
        return result
    }

    var isReady: Bool { missingTools.isEmpty }
}

struct WebLinkToolLocator: Sendable {
    let environment: [String: String]
    let homeDirectory: URL

    func resolveToolchain() -> WebLinkToolchain {
        WebLinkToolchain(
            ytDLPURL: locate(WebLinkTool.ytDLP.rawValue),
            ffmpegURL: locate(WebLinkTool.ffmpeg.rawValue),
            homebrewURL: locate("brew")
        )
    }

    func locate(_ executableName: String) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(executableName)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    private var searchDirectories: [URL] {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        paths.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
        ])

        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum WebLinkURLValidator {
    static func validatedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 8_192,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }
}

enum WebLinkDownloadRequest {
    static func make(
        ytDLPURL: URL,
        ffmpegURL: URL,
        sourceURL: URL,
        outputDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WebLinkProcessRequest {
        WebLinkProcessRequest(
            executableURL: ytDLPURL,
            arguments: [
                "--no-config",
                "--no-playlist",
                "--restrict-filenames",
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", "0",
                "--ffmpeg-location", ffmpegURL.deletingLastPathComponent().path,
                "--paths", outputDirectory.path,
                "--output", "%(title).180B-%(id)s.%(ext)s",
                "--", sourceURL.absoluteString,
            ],
            environment: environment,
            workingDirectory: outputDirectory
        )
    }
}

struct WebLinkToolInstaller: Sendable {
    let runner: any WebLinkProcessRunning

    func install(
        missingTools: [WebLinkTool],
        homebrewURL: URL,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard !missingTools.isEmpty else { return }
        let request = WebLinkProcessRequest(
            executableURL: homebrewURL,
            arguments: ["install"] + missingTools.map(\.formula),
            environment: environment,
            workingDirectory: workingDirectory
        )
        let result = try await runner.run(request)
        guard result.exitCode == 0 else {
            throw WebLinkPluginError.toolInstallationFailed(result.diagnosticOutput)
        }
    }
}

enum WebLinkPluginError: LocalizedError {
    case invalidURL
    case notActive
    case missingTools([WebLinkTool])
    case homebrewUnavailable
    case toolInstallationFailed(String)
    case downloadFailed(String)
    case noSupportedMedia
    case transcriptionQueueRejected

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            webLinkLocalized("The link must be a valid HTTP or HTTPS URL.")
        case .notActive:
            webLinkLocalized("The Web Link add-on is not active.")
        case .missingTools(let tools):
            String(
                format: webLinkLocalized("Missing helper tools: %@. Open the add-on settings to install them."),
                tools.map(\.rawValue).joined(separator: ", ")
            )
        case .homebrewUnavailable:
            webLinkLocalized("Homebrew was not found. Install the helper tools manually or install Homebrew first.")
        case .toolInstallationFailed(let diagnostic):
            diagnostic.isEmpty
                ? webLinkLocalized("Homebrew could not install the helper tools.")
                : diagnostic
        case .downloadFailed(let diagnostic):
            diagnostic.isEmpty
                ? webLinkLocalized("The media download failed.")
                : diagnostic
        case .noSupportedMedia:
            webLinkLocalized("The download did not produce a supported audio or video file.")
        case .transcriptionQueueRejected:
            webLinkLocalized("TypeWhisper could not add the downloaded media to the transcription queue.")
        }
    }
}

@objc(WebLinkPlugin)
final class WebLinkPlugin: NSObject,
    MediaImportPlugin,
    PluginUserInterfaceProviding,
    PluginSettingsWindowLayoutProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.web-link"
    static let pluginName = "Web Link Transcription"

    private struct State {
        var host: (any HostServices)?
    }

    private static let supportedExtensions = Set([
        "wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "mp4", "mov", "mkv", "webm"
    ])

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runner: any WebLinkProcessRunning
    private let environment: [String: String]
    private let homeDirectory: URL

    required override convenience init() {
        self.init(
            runner: WebLinkProcessRunner(),
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    init(
        runner: any WebLinkProcessRunning,
        environment: [String: String],
        homeDirectory: URL
    ) {
        self.runner = runner
        self.environment = environment
        self.homeDirectory = homeDirectory
        super.init()
    }

    func activate(host: HostServices) {
        state.withLock { $0.host = host }
        let importsDirectory = host.pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
        Task.detached(priority: .utility) {
            Self.removeStaleImports(in: importsDirectory)
        }
    }

    func deactivate() {
        state.withLock { $0.host = nil }
    }

    @MainActor var mediaImportId: String { "web-link" }
    @MainActor var mediaImportDisplayName: String { webLinkLocalized("Web Link") }

    @MainActor var appMenuCommands: [PluginCommandDescriptor] {
        [transcribeWebLinkCommand, openSettingsCommand]
    }

    @MainActor var primaryMenuBarCommands: [PluginCommandDescriptor] {
        [transcribeWebLinkCommand, openSettingsCommand]
    }

    @MainActor var settingsSidebarItems: [PluginSettingsSidebarItemDescriptor] {
        [
            PluginSettingsSidebarItemDescriptor(
                id: "web-link-transcription",
                title: webLinkLocalized("Web Link Transcription"),
                systemImageName: "link"
            )
        ]
    }

    @MainActor
    func settingsSidebarView(for itemId: String) -> AnyView? {
        guard itemId == "web-link-transcription" else { return nil }
        return AnyView(WebLinkTranscriptionSidebarView(plugin: self))
    }

    @MainActor
    func performPluginCommand(_ commandId: String) {
        switch commandId {
        case "transcribe-web-link":
            state.withLock { $0.host }?.openSettingsSidebarItem("web-link-transcription")
        case "open-settings":
            state.withLock { $0.host }?.openPluginSettings()
        default:
            break
        }
    }

    @MainActor private var transcribeWebLinkCommand: PluginCommandDescriptor {
        PluginCommandDescriptor(
            id: "transcribe-web-link",
            title: webLinkLocalized("Transcribe Web Link…"),
            systemImageName: "link.badge.plus"
        )
    }

    @MainActor private var openSettingsCommand: PluginCommandDescriptor {
        PluginCommandDescriptor(
            id: "open-settings",
            title: webLinkLocalized("Web Link Transcription Settings…"),
            systemImageName: "link"
        )
    }

    @MainActor var mediaImportAvailability: PluginMediaImportAvailability {
        let missing = toolchain().missingTools
        guard missing.isEmpty else {
            return PluginMediaImportAvailability(
                isAvailable: false,
                unavailableReason: WebLinkPluginError.missingTools(missing).localizedDescription
            )
        }
        return .available
    }

    @MainActor
    func canImportMedia(from url: URL) -> Bool {
        WebLinkURLValidator.validatedURL(from: url.absoluteString) != nil
    }

    @MainActor
    func importMedia(
        from url: URL,
        onProgress: @Sendable @escaping (PluginMediaImportProgress) -> Bool
    ) async throws -> PluginImportedMedia {
        guard let validatedURL = WebLinkURLValidator.validatedURL(from: url.absoluteString) else {
            throw WebLinkPluginError.invalidURL
        }
        guard let host = state.withLock({ $0.host }) else {
            throw WebLinkPluginError.notActive
        }

        let tools = toolchain()
        guard let ytDLPURL = tools.ytDLPURL,
              let ffmpegURL = tools.ffmpegURL else {
            throw WebLinkPluginError.missingTools(tools.missingTools)
        }

        let token = UUID().uuidString
        let importsDirectory = host.pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
        let jobDirectory = importsDirectory.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        do {
            guard onProgress(PluginMediaImportProgress(status: webLinkLocalized("Downloading media…"))) else {
                throw CancellationError()
            }
            let request = WebLinkDownloadRequest.make(
                ytDLPURL: ytDLPURL,
                ffmpegURL: ffmpegURL,
                sourceURL: validatedURL,
                outputDirectory: jobDirectory,
                environment: environment
            )
            let downloadingProgress = PluginMediaImportProgress(
                status: webLinkLocalized("Downloading media…")
            )
            let result = try await withThrowingTaskGroup(of: WebLinkProcessResult.self) { group in
                group.addTask { [runner] in
                    try await runner.run(request)
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .milliseconds(100))
                        guard onProgress(downloadingProgress) else {
                            throw CancellationError()
                        }
                    }
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw WebLinkPluginError.downloadFailed(Self.userFacingDiagnostic(result.diagnosticOutput))
            }

            let mediaURL = try Self.findImportedMedia(in: jobDirectory)
            let displayName = mediaURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            _ = onProgress(PluginMediaImportProgress(fractionCompleted: 1, status: webLinkLocalized("Download complete")))
            return PluginImportedMedia(
                localFileURL: mediaURL,
                displayName: displayName,
                cleanupToken: token
            )
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw error
        }
    }

    @MainActor
    func removeImportedMedia(_ media: PluginImportedMedia) async {
        guard let host = state.withLock({ $0.host }),
              let token = media.cleanupToken,
              UUID(uuidString: token) != nil else { return }
        let importsDirectory = host.pluginDataDirectory
            .appendingPathComponent("Imports", isDirectory: true)
            .standardizedFileURL
        let jobDirectory = importsDirectory
            .appendingPathComponent(token, isDirectory: true)
            .standardizedFileURL
        guard jobDirectory.deletingLastPathComponent() == importsDirectory else { return }
        try? FileManager.default.removeItem(at: jobDirectory)
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(WebLinkSettingsView(plugin: self))
    }

    var preferredSettingsWindowSize: CGSize? { CGSize(width: 620, height: 460) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 520, height: 400) }

    func toolchain() -> WebLinkToolchain {
        WebLinkToolLocator(environment: environment, homeDirectory: homeDirectory).resolveToolchain()
    }

    func installMissingToolsWithHomebrew() async throws {
        guard let host = state.withLock({ $0.host }) else {
            throw WebLinkPluginError.notActive
        }
        let tools = toolchain()
        guard let homebrewURL = tools.homebrewURL else {
            throw WebLinkPluginError.homebrewUnavailable
        }
        try await WebLinkToolInstaller(runner: runner).install(
            missingTools: tools.missingTools,
            homebrewURL: homebrewURL,
            workingDirectory: host.pluginDataDirectory,
            environment: environment
        )
        host.notifyCapabilitiesChanged()
    }

    @MainActor
    func enqueueImportedMediaForTranscription(_ media: PluginImportedMedia) async -> Bool {
        guard let host = state.withLock({ $0.host }) else { return false }
        return await host.enqueueImportedMediaForTranscription(
            media,
            fromMediaImporterId: mediaImportId
        )
    }

    func openSettingsWindow() {
        state.withLock { $0.host }?.openPluginSettings()
    }

    private static func findImportedMedia(in directory: URL) throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }

        guard let mediaURL = candidates.max(by: { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return left < right
        }) else {
            throw WebLinkPluginError.noSupportedMedia
        }
        return mediaURL
    }

    private static func userFacingDiagnostic(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .suffix(12)
            .joined(separator: "\n")
        return String(lines.prefix(4_000))
    }

    private static func removeStaleImports(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

private final class WebLinkImportActivity: @unchecked Sendable {
    private let isActive = OSAllocatedUnfairLock(initialState: true)

    var shouldContinue: Bool {
        isActive.withLock { $0 }
    }

    func cancel() {
        isActive.withLock { $0 = false }
    }
}

@MainActor
final class WebLinkTranscriptionSidebarViewModel: ObservableObject {
    @Published var link = ""
    @Published var progress: PluginMediaImportProgress?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var isImporting = false

    let plugin: WebLinkPlugin
    private var importTask: Task<Void, Never>?
    private var activeImportID: UUID?
    private var importActivity: WebLinkImportActivity?

    init(plugin: WebLinkPlugin) {
        self.plugin = plugin
    }

    var canSubmit: Bool {
        !isImporting
            && WebLinkURLValidator.validatedURL(from: link) != nil
            && plugin.mediaImportAvailability.isAvailable
    }

    func importLink() {
        guard !isImporting else { return }
        guard let sourceURL = WebLinkURLValidator.validatedURL(from: link) else {
            errorMessage = webLinkLocalized("The link must be a valid HTTP or HTTPS URL.")
            return
        }
        guard plugin.mediaImportAvailability.isAvailable else {
            errorMessage = plugin.mediaImportAvailability.unavailableReason
                ?? webLinkLocalized("The Web Link add-on is not ready.")
            return
        }

        isImporting = true
        errorMessage = nil
        successMessage = nil
        progress = PluginMediaImportProgress(status: webLinkLocalized("Preparing web link download"))
        let importID = UUID()
        let activity = WebLinkImportActivity()
        activeImportID = importID
        importActivity = activity

        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let importedMedia = try await plugin.importMedia(
                    from: sourceURL,
                    onProgress: { [weak self] progress in
                        guard activity.shouldContinue else { return false }
                        Task { @MainActor [weak self] in
                            guard self?.activeImportID == importID else { return }
                            self?.progress = progress
                        }
                        return activity.shouldContinue
                    }
                )
                guard !Task.isCancelled, activeImportID == importID else {
                    await plugin.removeImportedMedia(importedMedia)
                    return
                }
                guard await plugin.enqueueImportedMediaForTranscription(importedMedia) else {
                    await plugin.removeImportedMedia(importedMedia)
                    throw WebLinkPluginError.transcriptionQueueRejected
                }

                guard activeImportID == importID else { return }
                link = ""
                successMessage = webLinkLocalized("The downloaded media was added to the transcription queue.")
            } catch is CancellationError {
                // Cancellation is an explicit user action and needs no error banner.
            } catch {
                guard activeImportID == importID else { return }
                errorMessage = error.localizedDescription
            }

            guard activeImportID == importID else { return }
            activity.cancel()
            progress = nil
            isImporting = false
            importTask = nil
            activeImportID = nil
            importActivity = nil
        }
    }

    func cancelImport() {
        importActivity?.cancel()
        importActivity = nil
        activeImportID = nil
        importTask?.cancel()
        importTask = nil
        progress = nil
        isImporting = false
    }
}

@MainActor
private struct WebLinkTranscriptionSidebarView: View {
    @StateObject private var viewModel: WebLinkTranscriptionSidebarViewModel
    @FocusState private var isLinkFieldFocused: Bool

    init(plugin: WebLinkPlugin) {
        _viewModel = StateObject(
            wrappedValue: WebLinkTranscriptionSidebarViewModel(plugin: plugin)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(webLinkLocalized("Web Link Transcription"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(webLinkLocalized("Transcribe audio from a web link"))
                            .font(.headline)

                        Text(webLinkLocalized("Paste a supported video or audio link. The add-on downloads its audio and adds it to TypeWhisper's transcription queue."))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField(
                                webLinkLocalized("Paste a video or audio link"),
                                text: $viewModel.link
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($isLinkFieldFocused)
                            .onSubmit {
                                if viewModel.canSubmit {
                                    viewModel.importLink()
                                }
                            }
                            .disabled(viewModel.isImporting)
                            .accessibilityIdentifier("webLinkTranscription.link")

                            if viewModel.isImporting {
                                Button(webLinkLocalized("Cancel"), role: .cancel) {
                                    viewModel.cancelImport()
                                }
                            } else {
                                Button(webLinkLocalized("Add Link")) {
                                    viewModel.importLink()
                                }
                                .disabled(!viewModel.canSubmit)
                                .accessibilityIdentifier("webLinkTranscription.addLink")
                            }
                        }

                        if let progress = viewModel.progress {
                            HStack(spacing: 10) {
                                ProgressView(value: progress.fractionCompleted)
                                    .frame(maxWidth: 180)
                                if let status = progress.status {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let errorMessage = viewModel.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        if let successMessage = viewModel.successMessage {
                            Label(successMessage, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    if !viewModel.plugin.mediaImportAvailability.isAvailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                viewModel.plugin.mediaImportAvailability.unavailableReason
                                    ?? webLinkLocalized("The Web Link add-on is not ready.")
                            )
                            .foregroundStyle(.secondary)

                            Button(webLinkLocalized("Open add-on settings…")) {
                                viewModel.plugin.openSettingsWindow()
                            }
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isLinkFieldFocused = true
            }
        }
    }
}

@MainActor
private struct WebLinkSettingsView: View {
    let plugin: WebLinkPlugin

    @State private var toolchain = WebLinkToolchain(ytDLPURL: nil, ffmpegURL: nil, homebrewURL: nil)
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var showInstallConfirmation = false

    var body: some View {
        Form {
            Section(webLinkLocalized("Web Link Transcription")) {
                Text(webLinkLocalized("Download audio from a supported web link and pass it to TypeWhisper's regular file-transcription queue."))
                    .foregroundStyle(.secondary)
            }

            Section(webLinkLocalized("Helper tools")) {
                toolRow(name: "yt-dlp", url: toolchain.ytDLPURL)
                toolRow(name: "ffmpeg", url: toolchain.ffmpegURL)

                if toolchain.missingTools.isEmpty {
                    Label(webLinkLocalized("Ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let homebrewURL = toolchain.homebrewURL {
                    Button {
                        showInstallConfirmation = true
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(webLinkLocalized("Install missing tools with Homebrew"), systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isInstalling)

                    Text(String(format: webLinkLocalized("Homebrew found at %@."), homebrewURL.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(webLinkLocalized("Homebrew was not found. Install yt-dlp and ffmpeg manually, then check again."))
                        .foregroundStyle(.secondary)
                    Link(webLinkLocalized("Open Homebrew setup"), destination: URL(string: "https://brew.sh/")!)
                }

                if let installError {
                    Text(installError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Button(webLinkLocalized("Check again")) {
                    refresh()
                }
                .disabled(isInstalling)
            }

            Section {
                Text(webLinkLocalized("No helper tool is downloaded without confirmation. Homebrew verifies and manages the installed packages."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .confirmationDialog(
            webLinkLocalized("Install helper tools?"),
            isPresented: $showInstallConfirmation
        ) {
            Button(webLinkLocalized("Install with Homebrew")) {
                install()
            }
            Button(webLinkLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: webLinkLocalized("Homebrew will download and install: %@"),
                    toolchain.missingTools.map(\.rawValue).joined(separator: ", ")
                )
            )
        }
    }

    @ViewBuilder
    private func toolRow(name: String, url: URL?) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let url {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(webLinkLocalized("Not installed"))
                    .foregroundStyle(.secondary)
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func refresh() {
        toolchain = plugin.toolchain()
        installError = nil
    }

    private func install() {
        isInstalling = true
        installError = nil
        Task {
            do {
                try await plugin.installMissingToolsWithHomebrew()
                refresh()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }
}

private func webLinkLocalized(_ key: String.LocalizationValue) -> String {
    #if SWIFT_PACKAGE
    String(localized: key, bundle: .module)
    #else
    String(localized: key, bundle: Bundle(for: WebLinkPlugin.self))
    #endif
}
