import SwiftUI

struct APISettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared

    var body: some View {
        Form {
            Section {
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
                        Text(String(localized: "Port"))
                        Spacer()
                        TextField("8978", value: $viewModel.port, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                viewModel.restartIfNeeded()
                            }
                    }

                    HStack {
                        Image(systemName: viewModel.isRunning ? "circle.fill" : "circle.fill")
                            .foregroundStyle(viewModel.isRunning ? .green : .orange)
                            .font(.caption2)
                        Text(viewModel.isRunning
                             ? String(localized: "Running on port \(viewModel.port)")
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

            if viewModel.isEnabled {
                Section(String(localized: "Usage Examples")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Check status:"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("curl http://127.0.0.1:\(viewModel.port)/v1/status")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Divider()

                        Text(String(localized: "Transcribe audio:"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("curl -X POST http://127.0.0.1:\(viewModel.port)/v1/transcribe \\\n  -F \"file=@audio.wav\"")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Divider()

                        Text(String(localized: "List models:"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("curl http://127.0.0.1:\(viewModel.port)/v1/models")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
