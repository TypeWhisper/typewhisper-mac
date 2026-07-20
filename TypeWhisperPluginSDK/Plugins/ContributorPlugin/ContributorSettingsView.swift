import SwiftUI

struct ContributorSettingsView: View {
    @ObservedObject var plugin: ContributorPlugin
    @State private var captureEnabled = false
    @State private var showingSendConfirmation = false

    private var selectedRecord: ContributionRecord? {
        plugin.records.first { $0.id == plugin.selectedPreviewId }
    }

    private var locallySelectedCount: Int {
        plugin.records.filter {
            plugin.selectedIds.contains($0.id) && $0.status == .local
        }.count
    }

    private var hasRemoteRecords: Bool {
        plugin.records.contains(where: \.status.isRemote)
    }

    private var sentRecordCount: Int {
        plugin.records.filter(\.status.isRemote).count
    }

    var body: some View {
        VStack(spacing: 0) {
            captureSection
            Divider()
            queueHeader
            Divider()
            queueContent
            Divider()
            submissionFooter
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            captureEnabled = plugin.captureEnabled
            plugin.reloadQueue()
        }
        .onChange(of: plugin.selectedIds) { _, _ in
            plugin.sendConfirmed = false
        }
        .alert(
            contributorText(
                "Send selected changes?",
                de: "Ausgewählte Änderungen senden?",
                ja: "選択した変更を送信しますか？"
            ),
            isPresented: $showingSendConfirmation
        ) {
            Button(contributorText("Cancel", de: "Abbrechen", ja: "キャンセル"), role: .cancel) {}
            Button(contributorText("Send", de: "Senden", ja: "送信")) {
                plugin.sendConfirmed = true
                plugin.sendSelected()
            }
        } message: {
            Text(contributorText(
                "Both complete text versions of \(locallySelectedCount) changes will be sent for review. You can delete a submission until it is included in a validated training dataset.",
                de: "Von \(locallySelectedCount) Änderungen werden jeweils beide vollständigen Textversionen zur Prüfung gesendet. Du kannst eine Einsendung löschen, bis sie in einen validierten Trainingsdatensatz übernommen wurde.",
                ja: "\(locallySelectedCount)件の変更について、修正前後の全文をレビュー用に送信します。検証済みの学習データセットに追加されるまでは削除できます。"
            ))
        }
    }

    private var captureSection: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(contributorText(
                    "Collect corrections",
                    de: "Korrekturen sammeln",
                    ja: "修正を収集"
                ))
                .font(.headline)

                Text(contributorText(
                    "Only manually changed before/after text is kept locally. Audio, target app, URL, and unchanged dictations are excluded.",
                    de: "Nur manuell geänderte Vorher-/Nachher-Texte bleiben lokal. Audio, Ziel-App, URL und unveränderte Diktate sind ausgeschlossen.",
                    ja: "手動で変更した修正前後のテキストのみローカルに保存します。音声、対象アプリ、URL、未変更の音声入力は除外されます。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: ContributorPlugin.contributionPolicyURL) {
                    Label(
                        contributorText(
                            "Contribution and privacy policy",
                            de: "Beitrags- und Datenschutzregeln",
                            ja: "提供とプライバシーに関する方針"
                        ),
                        systemImage: "arrow.up.right.square"
                    )
                }
                .font(.caption)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: $captureEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: captureEnabled) { _, enabled in
                    plugin.updateCaptureEnabled(enabled)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var queueHeader: some View {
        HStack(spacing: 8) {
            Text(contributorText("Changes", de: "Änderungen", ja: "変更"))
                .font(.headline)

            Text("\(plugin.records.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if sentRecordCount > 0 {
                Label(
                    contributorText(
                        "\(sentRecordCount) sent",
                        de: "\(sentRecordCount) gesendet",
                        ja: "\(sentRecordCount)件送信済み"
                    ),
                    systemImage: "paperplane.fill"
                )
                .font(.caption)
                .foregroundStyle(.blue)
            }

            if locallySelectedCount > 0 {
                Text(contributorText(
                    "\(locallySelectedCount) selected",
                    de: "\(locallySelectedCount) ausgewählt",
                    ja: "\(locallySelectedCount)件選択"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if hasRemoteRecords {
                Button {
                    plugin.refreshStatuses()
                } label: {
                    Label(
                        contributorText(
                            "Refresh status",
                            de: "Status aktualisieren",
                            ja: "状況を更新"
                        ),
                        systemImage: "arrow.clockwise"
                    )
                }
                .labelStyle(.iconOnly)
                .help(contributorText(
                    "Refresh review status",
                    de: "Prüfstatus aktualisieren",
                    ja: "レビュー状況を更新"
                ))
                .disabled(plugin.isWorking)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var queueContent: some View {
        if plugin.records.isEmpty {
            ContentUnavailableView(
                contributorText(
                    "No corrections",
                    de: "Keine Korrekturen",
                    ja: "修正はありません"
                ),
                systemImage: "checkmark.bubble"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(plugin.records) { record in
                            ContributionRow(
                                record: record,
                                isSelected: plugin.selectedIds.contains(record.id),
                                isPreviewed: plugin.selectedPreviewId == record.id,
                                onToggle: { plugin.toggleSelection(record.id) },
                                onPreview: { plugin.selectedPreviewId = record.id },
                                onDelete: { plugin.delete(record) }
                            )
                            Divider()
                        }
                    }
                }
                .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)

                if let selectedRecord {
                    ContributionPreview(record: selectedRecord)
                        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        contributorText(
                            "Select a change",
                            de: "Änderung auswählen",
                            ja: "変更を選択"
                        ),
                        systemImage: "text.magnifyingglass"
                    )
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var submissionFooter: some View {
        HStack(spacing: 12) {
            if plugin.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let message = plugin.activityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(plugin.activityIsError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                showingSendConfirmation = true
            } label: {
                Label(
                    contributorText(
                        "Send \(locallySelectedCount)",
                        de: "\(locallySelectedCount) senden",
                        ja: "\(locallySelectedCount)件を送信"
                    ),
                    systemImage: "paperplane"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(locallySelectedCount == 0 || plugin.isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ContributionRow: View {
    let record: ContributionRecord
    let isSelected: Bool
    let isPreviewed: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if record.status == .local {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                }
                .buttonStyle(.plain)
                .help(contributorText(
                    "Select for sending",
                    de: "Zum Versand auswählen",
                    ja: "送信用に選択"
                ))
                .frame(width: 18, height: 18)
            } else {
                Image(systemName: contributionStatusSymbol(record.status))
                    .foregroundStyle(contributionStatusColor(record.status))
                    .frame(width: 18, height: 18)
                    .help(contributionStatusTitle(record.status))
            }

            Button(action: onPreview) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.correctedText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Label(
                            contributionStatusTitle(record.status),
                            systemImage: contributionStatusSymbol(record.status)
                        )
                        .foregroundStyle(contributionStatusColor(record.status))
                        if let language = record.language {
                            Text(language)
                        }
                        Text(record.capturedAt, style: .date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help(contributorText(
                "Delete correction",
                de: "Korrektur löschen",
                ja: "修正を削除"
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isPreviewed ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPreview)
    }
}

private struct ContributionPreview: View {
    let record: ContributionRecord

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(contributorText("Preview", de: "Vorschau", ja: "プレビュー"))
                    .font(.headline)
                Spacer()
                Label(
                    contributionStatusTitle(record.status),
                    systemImage: contributionStatusSymbol(record.status)
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(contributionStatusColor(record.status))
                Text(record.capturedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewSection(
                        title: contributorText("Before", de: "Vorher", ja: "修正前"),
                        text: record.originalText,
                        color: .red
                    )

                    Divider()

                    previewSection(
                        title: contributorText("After", de: "Nachher", ja: "修正後"),
                        text: record.correctedText,
                        color: .green
                    )

                    Divider()

                    HStack(spacing: 12) {
                        Label(record.engineId, systemImage: "waveform")
                        if let language = record.language {
                            Label(language, systemImage: "character.bubble")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .textSelection(.enabled)
        }
    }

    private func previewSection(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func contributionStatusTitle(_ status: ContributionLocalStatus) -> String {
    switch status {
    case .local:
        contributorText("Ready to send", de: "Bereit zum Senden", ja: "送信準備完了")
    case .pending:
        contributorText(
            "Sent · Pending review",
            de: "Gesendet · Prüfung ausstehend",
            ja: "送信済み・レビュー待ち"
        )
    case .accepted:
        contributorText("Accepted", de: "Angenommen", ja: "承認済み")
    case .rejected:
        contributorText("Rejected", de: "Abgelehnt", ja: "却下")
    case .quarantined:
        contributorText(
            "Sent · Manual review",
            de: "Gesendet · Manuelle Prüfung",
            ja: "送信済み・要確認"
        )
    }
}

private func contributionStatusSymbol(_ status: ContributionLocalStatus) -> String {
    switch status {
    case .local:
        "tray"
    case .pending:
        "paperplane.circle.fill"
    case .accepted:
        "checkmark.seal.fill"
    case .rejected:
        "xmark.octagon.fill"
    case .quarantined:
        "exclamationmark.triangle.fill"
    }
}

private func contributionStatusColor(_ status: ContributionLocalStatus) -> Color {
    switch status {
    case .local:
        .secondary
    case .pending:
        .blue
    case .accepted:
        .green
    case .rejected:
        .red
    case .quarantined:
        .orange
    }
}
