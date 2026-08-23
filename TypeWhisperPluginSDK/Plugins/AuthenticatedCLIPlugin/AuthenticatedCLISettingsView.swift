import AppKit
import SwiftUI

struct AuthenticatedCLISettingsView: View {
    let plugin: AuthenticatedCLIPlugin

    @State private var statuses: [CLIProviderStatus] = []
    @State private var isRefreshing = false
    private let bundle = Bundle(for: AuthenticatedCLIPlugin.self)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                securityNotice

                ForEach(statuses, id: \.kind.rawValue) { status in
                    providerCard(status)
                }

                HStack {
                    Button {
                        refresh(force: true)
                    } label: {
                        Label(
                            String(localized: "Check again", bundle: bundle),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isRefreshing)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Link(
                        String(localized: "Setup guide", bundle: bundle),
                        destination: URL(string: "https://www.typewhisper.com/addons/authenticated-cli/macos/")!
                    )
                }
            }
            .padding(24)
        }
        .task {
            statuses = plugin.statusesSnapshot()
            await refreshNow(force: false)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(localized: "Authenticated Provider CLIs", bundle: bundle))
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }

            Text(String(
                localized: "Use the accounts already signed in to supported provider CLIs. No separate API key is stored in TypeWhisper.",
                bundle: bundle
            ))
            .foregroundStyle(.secondary)
        }
    }

    private var securityNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.blue)
            Text(String(
                localized: "Only the workflow instruction and transcript text are sent. Each request runs non-interactively in a temporary folder with tools, sessions, project rules, and update checks disabled where the CLI supports it.",
                bundle: bundle
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func providerCard(_ status: CLIProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.kind.displayName)
                        .font(.headline)
                    Text(providerSubtitle(status.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(statusLabel(status.state), systemImage: statusSymbol(status.state))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor(status.state))
            }

            if let detail = status.detail {
                Text(localizedDetail(status, fallback: detail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let version = status.version {
                LabeledContent(String(localized: "Version", bundle: bundle)) {
                    Text(version)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let path = status.executableURL?.path ?? plugin.selectedPath(for: status.kind) {
                LabeledContent(String(localized: "Executable", bundle: bundle)) {
                    Text(path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if status.kind == .codex, status.isReady {
                codexModelCatalogDetails
            } else if status.kind == .antigravity, status.isReady {
                antigravityModelCatalogDetails
            }

            HStack {
                Button(String(localized: "Choose…", bundle: bundle)) {
                    chooseExecutable(for: status.kind)
                }
                if plugin.selectedPath(for: status.kind) != nil {
                    Button(String(localized: "Use automatic detection", bundle: bundle)) {
                        Task {
                            isRefreshing = true
                            await plugin.setSelectedExecutable(nil, for: status.kind)
                            statuses = plugin.statusesSnapshot()
                            isRefreshing = false
                        }
                    }
                }
                Spacer()
                if let documentationURL = status.kind.documentationURL {
                    Link(String(localized: "CLI documentation", bundle: bundle), destination: documentationURL)
                        .font(.callout)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var codexModelCatalogDetails: some View {
        let snapshot = plugin.codexModelCatalogSnapshot()
        if let catalog = snapshot.catalog, !catalog.models.isEmpty {
            LabeledContent(String(localized: "Available models", bundle: bundle)) {
                Text(catalog.models.count, format: .number)
                    .font(.caption.monospacedDigit())
            }

            if let defaultModelID = catalog.defaultModelID,
               let defaultModel = catalog.models.first(where: { $0.id == defaultModelID }) {
                LabeledContent(String(localized: "CLI default", bundle: bundle)) {
                    Text(defaultModel.displayName)
                        .font(.caption)
                        .textSelection(.enabled)
                }

                if let defaultEffortID = defaultModel.defaultReasoningEffort {
                    LabeledContent(String(localized: "Default effort", bundle: bundle)) {
                        Text(AuthenticatedCLIPlugin.effortDisplayName(defaultEffortID))
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }

            Text(String(
                localized: "Models and model-specific effort levels are loaded from the signed-in Codex CLI and refreshed automatically.",
                bundle: bundle
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if snapshot.refreshError != nil {
            Label(
                String(localized: "The Codex model list could not be refreshed. The last cached list remains available.", bundle: bundle),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var antigravityModelCatalogDetails: some View {
        let snapshot = plugin.antigravityModelCatalogSnapshot()
        if let catalog = snapshot.catalog, !catalog.models.isEmpty {
            LabeledContent(String(localized: "Available models", bundle: bundle)) {
                Text(catalog.models.count, format: .number)
                    .font(.caption.monospacedDigit())
            }

            Text(String(
                localized: "Models are loaded from the signed-in Antigravity CLI. Effort can be set to Low, Medium, or High.",
                bundle: bundle
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if snapshot.refreshError != nil {
            Label(
                String(localized: "The Antigravity model list could not be refreshed. The last cached list remains available.", bundle: bundle),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func refresh(force: Bool) {
        Task { await refreshNow(force: force) }
    }

    @MainActor
    private func refreshNow(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await plugin.refreshAvailability(force: force)

        let deadline = ContinuousClock.now + .seconds(20)
        while plugin.isRefreshingAvailability, ContinuousClock.now < deadline {
            statuses = plugin.statusesSnapshot()
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        statuses = plugin.statusesSnapshot()
    }

    @MainActor
    private func chooseExecutable(for kind: CLIProviderKind) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose CLI executable", bundle: bundle)
        panel.prompt = String(localized: "Choose", bundle: bundle)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            isRefreshing = true
            await plugin.setSelectedExecutable(url, for: kind)
            statuses = plugin.statusesSnapshot()
            isRefreshing = false
        }
    }

    private func providerSubtitle(_ kind: CLIProviderKind) -> String {
        switch kind {
        case .codex:
            String(localized: "OpenAI account via Codex", bundle: bundle)
        case .claude:
            String(localized: "Anthropic account via Claude Code", bundle: bundle)
        case .antigravity:
            String(localized: "Best-effort integration", bundle: bundle)
        }
    }

    private func statusLabel(_ state: CLIProviderAvailabilityState) -> String {
        switch state {
        case .checking: String(localized: "Checking…", bundle: bundle)
        case .ready: String(localized: "Ready", bundle: bundle)
        case .missing: String(localized: "Not installed", bundle: bundle)
        case .signedOut: String(localized: "Sign-in required", bundle: bundle)
        case .incompatible: String(localized: "Incompatible", bundle: bundle)
        case .unavailable: String(localized: "Not live-tested", bundle: bundle)
        case .failed: String(localized: "Check failed", bundle: bundle)
        }
    }

    private func statusSymbol(_ state: CLIProviderAvailabilityState) -> String {
        switch state {
        case .checking: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .missing: "minus.circle"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .incompatible, .failed: "exclamationmark.triangle.fill"
        case .unavailable: "testtube.2"
        }
    }

    private func statusColor(_ state: CLIProviderAvailabilityState) -> Color {
        switch state {
        case .ready: .green
        case .checking: .secondary
        case .missing, .unavailable: .orange
        case .signedOut, .incompatible, .failed: .red
        }
    }

    private func localizedDetail(_ status: CLIProviderStatus, fallback: String) -> String {
        switch status.state {
        case .ready:
            String(localized: "Installed and authenticated.", bundle: bundle)
        case .missing:
            String(localized: "The CLI was not found in common installation locations.", bundle: bundle)
        case .signedOut:
            String(localized: "The CLI is installed, but no signed-in account was detected.", bundle: bundle)
        case .unavailable where status.kind == .antigravity:
            String(localized: "Support follows the documented Antigravity headless CLI contract. No signed-in installation was available for a live test.", bundle: bundle)
        default:
            fallback
        }
    }
}
