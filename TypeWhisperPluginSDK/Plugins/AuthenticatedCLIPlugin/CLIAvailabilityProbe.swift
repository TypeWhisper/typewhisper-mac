import Foundation

struct CLIAvailabilityProbe: Sendable {
    private let runner: any CLIProcessRunning
    private let baseEnvironment: [String: String]
    private let homeDirectory: URL

    init(
        runner: any CLIProcessRunning,
        baseEnvironment: [String: String],
        homeDirectory: URL
    ) {
        self.runner = runner
        self.baseEnvironment = baseEnvironment
        self.homeDirectory = homeDirectory
    }

    func probe(_ kind: CLIProviderKind, selectedPath: String?) async -> CLIProviderStatus {
        let candidates = CLIExecutableDiscovery.candidates(
            for: kind,
            selectedPath: selectedPath,
            environmentPath: baseEnvironment["PATH"],
            homeDirectory: homeDirectory
        )

        guard !candidates.isEmpty else {
            let manuallySelected = selectedPath?.isEmpty == false
            return status(
                kind,
                state: manuallySelected ? .incompatible : .missing,
                detail: manuallySelected
                    ? "The selected executable is missing, unsafe, or not executable."
                    : "No \(kind.executableName) executable was found."
            )
        }

        var lastFailure: CLIProviderStatus?
        for executableURL in candidates {
            let candidate = await probeCandidate(kind, executableURL: executableURL)
            switch candidate.state {
            case .ready, .signedOut, .unavailable:
                return candidate
            case .checking, .missing, .incompatible, .failed:
                lastFailure = candidate
            }
        }
        return lastFailure ?? status(kind, state: .missing, detail: "No compatible CLI was found.")
    }

    private func probeCandidate(
        _ kind: CLIProviderKind,
        executableURL: URL
    ) async -> CLIProviderStatus {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisper-CLI-Probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return status(
                kind,
                state: .failed,
                executableURL: executableURL,
                detail: "Could not create an isolated probe directory."
            )
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let environment = CLIEnvironment.sanitized(
            base: baseEnvironment,
            kind: kind,
            executableURL: executableURL,
            temporaryDirectory: temporaryDirectory
        )

        do {
            let versionResult = try await runProbe(
                executableURL: executableURL,
                arguments: kind.versionArguments,
                environment: environment,
                workingDirectory: temporaryDirectory
            )
            guard versionResult.exitCode == 0 else {
                return status(
                    kind,
                    state: .incompatible,
                    executableURL: executableURL,
                    detail: "The version probe exited with code \(versionResult.exitCode)."
                )
            }
            let version = firstNonemptyLine(versionResult)

            let helpResult = try await runProbe(
                executableURL: executableURL,
                arguments: kind.helpArguments,
                environment: environment,
                workingDirectory: temporaryDirectory
            )
            let help = try combinedOutput(helpResult)
            guard helpResult.exitCode == 0,
                  kind.requiredHelpTokens.allSatisfy(help.contains)
            else {
                let missing = kind.requiredHelpTokens.filter { !help.contains($0) }
                return status(
                    kind,
                    state: .incompatible,
                    executableURL: executableURL,
                    version: version,
                    detail: missing.isEmpty
                        ? "The CLI help probe failed."
                        : "Required isolation options are missing: \(missing.joined(separator: ", "))."
                )
            }

            let authentication = try await runProbe(
                executableURL: executableURL,
                arguments: kind.authenticationArguments,
                environment: environment,
                workingDirectory: temporaryDirectory,
                timeout: 15
            )
            let authenticated: Bool
            switch kind {
            case .codex:
                let output = try combinedOutput(authentication).lowercased()
                authenticated = authentication.exitCode == 0 && !output.contains("not logged")
            case .claude:
                authenticated = authentication.exitCode == 0 && claudeIsLoggedIn(authentication.standardOutput)
            case .antigravity:
                let output = try combinedOutput(authentication)
                authenticated = authentication.exitCode == 0
                    && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            guard authenticated else {
                return status(
                    kind,
                    state: .signedOut,
                    executableURL: executableURL,
                    version: version,
                    detail: "The CLI is installed but no authenticated account was detected."
                )
            }
            return status(
                kind,
                state: .ready,
                executableURL: executableURL,
                version: version,
                detail: "Installed and authenticated."
            )
        } catch {
            return status(
                kind,
                state: .failed,
                executableURL: executableURL,
                detail: error.localizedDescription
            )
        }
    }

    private func runProbe(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval = 5
    ) async throws -> CLIProcessResult {
        try await runner.run(CLIProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardInput: Data(),
            timeout: timeout,
            standardOutputLimit: 128 * 1024,
            standardErrorLimit: 64 * 1024
        ))
    }

    private func firstNonemptyLine(_ result: CLIProcessResult) -> String? {
        guard let output = try? combinedOutput(result) else { return nil }
        return output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func combinedOutput(_ result: CLIProcessResult) throws -> String {
        let data = result.standardOutput + result.standardError
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIPluginError.invalidOutput("Probe output is not valid UTF-8.")
        }
        return output
    }

    private func claudeIsLoggedIn(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["loggedIn"] as? Bool == true
    }

    private func status(
        _ kind: CLIProviderKind,
        state: CLIProviderAvailabilityState,
        executableURL: URL? = nil,
        version: String? = nil,
        detail: String? = nil
    ) -> CLIProviderStatus {
        CLIProviderStatus(
            kind: kind,
            state: state,
            executableURL: executableURL,
            version: version,
            detail: detail,
            checkedAt: Date()
        )
    }
}
