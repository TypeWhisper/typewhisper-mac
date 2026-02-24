import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared
    #if !APPSTORE
    @State private var cliInstalled = false
    @State private var cliSymlinkTarget = ""
    #endif

    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays: Int = 0

    var body: some View {
        Form {
            // MARK: - History
            Section(String(localized: "History")) {
                Picker(String(localized: "Auto-delete after"), selection: $historyRetentionDays) {
                    Text(String(localized: "Unlimited")).tag(0)
                    Text(String(localized: "30 days")).tag(30)
                    Text(String(localized: "60 days")).tag(60)
                    Text(String(localized: "90 days")).tag(90)
                    Text(String(localized: "180 days")).tag(180)
                }
                Text(String(localized: "Older entries are automatically removed at app launch."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - API Server
            Section(String(localized: "API Server")) {
                Toggle(String(localized: "Enable API Server"), isOn: $viewModel.isEnabled)
                    .onChange(of: viewModel.isEnabled) { _, enabled in
                        if enabled {
                            viewModel.startServer()
                        } else {
                            viewModel.stopServer()
                        }
                    }

                if viewModel.isEnabled {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(viewModel.isRunning ? .green : .orange)
                            .font(.caption2)
                        Text(viewModel.isRunning
                             ? String(localized: "Running on port \(String(viewModel.port))")
                             : String(localized: "Not running"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }

            #if !APPSTORE
            // MARK: - Command Line Tool
            Section(String(localized: "Command Line Tool")) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(cliInstalled ? .green : .orange)
                        .font(.caption2)
                    if cliInstalled {
                        Text(String(localized: "Installed at /usr/local/bin/typewhisper"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Not installed"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if cliInstalled {
                    Button(String(localized: "Uninstall")) {
                        uninstallCLI()
                    }
                } else {
                    Button(String(localized: "Install Command Line Tool")) {
                        installCLI()
                    }
                }

                Text(String(localized: "Requires the API server to be running. The CLI tool connects to TypeWhisper's API for fast transcription without model cold starts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            // MARK: - Usage Examples
            if viewModel.isEnabled {
                Section(String(localized: "Usage Examples")) {
                    #if !APPSTORE
                    if cliInstalled {
                        cliExamples
                    } else {
                        curlExamples
                    }
                    #else
                    curlExamples
                    #endif
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        #if !APPSTORE
        .onAppear { checkCLIInstallation() }
        #endif
    }

    // MARK: - Examples

    #if !APPSTORE
    private var cliExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Show help:"), "typewhisper --help")
            Divider()
            exampleRow(String(localized: "Check status:"), "typewhisper status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "typewhisper transcribe audio.wav")
            Divider()
            exampleRow(String(localized: "Transcribe with language:"), "typewhisper transcribe audio.wav --language de")
            Divider()
            exampleRow(String(localized: "JSON output:"), "typewhisper transcribe audio.wav --json")
            Divider()
            exampleRow(String(localized: "Pipe to clipboard:"), "typewhisper transcribe audio.wav | pbcopy")
            Divider()
            exampleRow(String(localized: "List models:"), "typewhisper models")
        }
    }
    #endif

    private var curlExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Check status:"), "curl http://127.0.0.1:\(viewModel.port)/v1/status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "curl -X POST http://127.0.0.1:\(viewModel.port)/v1/transcribe \\\n  -F \"file=@audio.wav\"")
            Divider()
            exampleRow(String(localized: "List models:"), "curl http://127.0.0.1:\(viewModel.port)/v1/models")
        }
    }

    private func exampleRow(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy"))
            }
        }
    }

    // MARK: - CLI Installation

    #if !APPSTORE
    private static let symlinkPath = "/usr/local/bin/typewhisper"

    private var cliBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/typewhisper-cli").path
    }

    private func checkCLIInstallation() {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: Self.symlinkPath) else {
            cliInstalled = false
            return
        }
        cliSymlinkTarget = dest
        cliInstalled = dest == cliBinaryPath
    }

    private func installCLI() {
        let target = cliBinaryPath
        let link = Self.symlinkPath
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(target)' '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func uninstallCLI() {
        let link = Self.symlinkPath
        let script = """
            do shell script "rm -f '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func runOsascript(_ source: String, completion: @escaping () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { _ in
            DispatchQueue.main.async { completion() }
        }
        try? process.run()
    }
    #endif
}
