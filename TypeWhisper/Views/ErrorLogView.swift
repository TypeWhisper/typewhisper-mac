import SwiftUI
import UniformTypeIdentifiers

struct ErrorLogView: View {
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService

    @State private var showClearConfirmation = false
    @State private var exportErrorMessage: String?

    var body: some View {
        Group {
            if errorLogService.entries.isEmpty {
                emptyState
            } else {
                errorList
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    exportDiagnostics()
                } label: {
                    Label(String(localized: "Export Diagnostics"), systemImage: "square.and.arrow.up")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label(String(localized: "Clear All"), systemImage: "trash")
                }
                .disabled(errorLogService.entries.isEmpty)
                .confirmationDialog(
                    String(localized: "Clear Error Log?"),
                    isPresented: $showClearConfirmation
                ) {
                    Button(String(localized: "Clear All"), role: .destructive) {
                        errorLogService.clearAll()
                    }
                } message: {
                    Text(String(localized: "This will permanently delete all recorded errors."))
                }
            }
        }
        .alert(String(localized: "Export Failed"), isPresented: exportErrorPresented) {
            Button(String(localized: "OK"), role: .cancel) {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "No errors recorded."))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorList: some View {
        List(errorLogService.entries) { entry in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.categoryIcon)
                    .foregroundStyle(.red)
                    .font(.system(size: 14))
                    .frame(width: 20, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.message)
                        .font(.callout)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        Text(entry.categoryDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("-")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Text(entry.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { presented in
                if !presented {
                    exportErrorMessage = nil
                }
            }
        )
    }

    private func exportDiagnostics() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "typewhisper-diagnostics-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try errorLogService.exportDiagnostics(to: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}
