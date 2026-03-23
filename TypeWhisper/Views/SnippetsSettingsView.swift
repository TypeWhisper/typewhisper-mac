import SwiftUI

struct SnippetsSettingsView: View {
    @ObservedObject private var viewModel = SnippetsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.snippets.isEmpty {
                emptyState
            } else {
                // Header with add button
                HStack {
                    Text(String(format: String(localized: "%d Snippets"), viewModel.snippets.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        viewModel.startCreating()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(String(localized: "Add new snippet"))
                    .accessibilityLabel(String(localized: "Add new snippet"))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.snippets) { snippet in
                            SnippetCardView(snippet: snippet, viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .sheet(isPresented: $viewModel.isEditing) {
            SnippetEditorSheet(viewModel: viewModel)
        }
        .alert(String(localized: "Error"), isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button(String(localized: "OK")) { viewModel.clearError() }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(String(localized: "No snippets yet"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Create snippets to automatically expand short triggers into longer text"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button(String(localized: "Add Snippet")) {
                    viewModel.startCreating()
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
}

// MARK: - Snippet Card

private struct SnippetCardView: View {
    let snippet: Snippet
    @ObservedObject var viewModel: SnippetsViewModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(snippet.trigger)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(snippet.replacement)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if snippet.caseSensitive {
                Text("Aa")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundStyle(.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { snippet.isEnabled },
                set: { _ in viewModel.toggleSnippet(snippet) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable \(snippet.trigger)"))
            .onTapGesture {}
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHovering ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            viewModel.startEditing(snippet)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(String(localized: "Edit")) {
                viewModel.startEditing(snippet)
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteSnippet(snippet)
            }
        }
    }
}

// MARK: - Editor Sheet

private struct SnippetEditorSheet: View {
    @ObservedObject var viewModel: SnippetsViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    enum Field {
        case trigger, replacement
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.isCreatingNew ? String(localized: "New Snippet") : String(localized: "Edit Snippet"))
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                GroupBox(String(localized: "Snippet")) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Trigger"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField(String(localized: "e.g. addr"), text: $viewModel.editTrigger)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .focused($focusedField, equals: .trigger)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Replacement"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $viewModel.editReplacement)
                                .font(.body)
                                .frame(height: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(.separator, lineWidth: 1)
                                )
                                .focused($focusedField, equals: .replacement)
                        }

                        Toggle(String(localized: "Case sensitive"), isOn: $viewModel.editCaseSensitive)
                    }
                    .padding(.vertical, 8)
                }

                GroupBox(String(localized: "Dynamic Placeholders")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Click to insert a placeholder:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            PlaceholderTag(
                                placeholder: "{{DATE}}",
                                title: String(localized: "Date"),
                                example: "04.02.2026"
                            ) {
                                viewModel.editReplacement += "{{DATE}}"
                            }
                            PlaceholderTag(
                                placeholder: "{{TIME}}",
                                title: String(localized: "Time"),
                                example: "19:30"
                            ) {
                                viewModel.editReplacement += "{{TIME}}"
                            }
                            PlaceholderTag(
                                placeholder: "{{CLIPBOARD}}",
                                title: String(localized: "Clipboard"),
                                example: String(localized: "Clipboard content")
                            ) {
                                viewModel.editReplacement += "{{CLIPBOARD}}"
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding()

            Divider()

            HStack {
                Button(String(localized: "Cancel")) {
                    viewModel.cancelEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Save")) {
                    viewModel.saveEditing()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.editTrigger.isEmpty || viewModel.editReplacement.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 450, idealWidth: 480, minHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            focusedField = .trigger
        }
    }
}

// MARK: - Placeholder Tag

private struct PlaceholderTag: View {
    let placeholder: String
    let title: String
    let example: String
    let onInsert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(placeholder)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    onInsert()
                }
                .help(String(localized: "Click to insert"))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
                Text(String(localized: "e.g.") + " " + example)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 100, alignment: .leading)
    }
}
