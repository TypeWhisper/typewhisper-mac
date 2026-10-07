import SwiftUI

/// The slim row above a History record's text that offers speaker detection,
/// shows its progress, or says why it cannot run.
struct HistorySpeakerDetectionRow: View {
    let record: TranscriptionRecord
    let hasAudio: Bool
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    /// Called before detection starts, so the transcript shows by speaker.
    let onStart: () -> Void

    var body: some View {
        if let stage = coordinator.stages[record.id] {
            row(symbol: "person.2.wave.2", tint: .accentColor) {
                progress(stage)
            } actions: {
                Button(String(localized: "Cancel")) {
                    coordinator.cancel(recordID: record.id)
                }
            }
        } else if record.speakerTranscriptData == nil, hasAudio, record.processingState == .ready {
            idle
        }
    }

    @ViewBuilder
    private var idle: some View {
        switch coordinator.startError(for: record) {
        case .premiumRequired:
            row(symbol: "lock.fill", tint: .purple) {
                title(String(localized: "speakers.premium.required"))
            } actions: {
                Button(String(localized: "speakers.premium.open")) {
                    SettingsNavigationCoordinator.shared.navigate(to: .premium)
                }
            }
        case .providerUnavailable:
            notice(String(localized: "speakers.status.providerUnavailable"))
        case .audioMissing:
            notice(String(localized: "speakers.status.audioMissing"))
        case .timingMissing:
            notice(String(localized: "speakers.status.timingMissing"))
        case nil:
            if record.speakerTranscriptState == .failed || record.speakerTranscriptState == .pending {
                row(symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    title(String(localized: "speakers.status.failed"))
                } actions: {
                    Button(String(localized: "speakers.action.tryAgain")) { start(speakerCount: nil) }
                }
            } else {
                invitation
            }
        }
    }

    private var invitation: some View {
        row {
            ConversationSketch()
        } content: {
            VStack(alignment: .leading, spacing: 1) {
                title(String(localized: "speakers.invite.title"))
                Text(String(localized: "speakers.invite.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } actions: {
            HStack(spacing: 2) {
                Button(String(localized: "speakers.toggle.title")) { start(speakerCount: nil) }
                    .buttonStyle(.borderedProminent)
                    .help(String(localized: "speakers.detect.help"))
                Menu {
                    Section(String(localized: "speakers.count.title")) {
                        Button(String(localized: "speakers.count.automatic")) { start(speakerCount: nil) }
                        ForEach(coordinator.selectableSpeakerCounts, id: \.self) { count in
                            Button(count.formatted()) { start(speakerCount: count) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "speakers.count.title"))
                .accessibilityLabel(String(localized: "speakers.count.title"))
            }
        }
    }

    private func start(speakerCount: Int?) {
        onStart()
        coordinator.start(recordID: record.id, speakerCount: speakerCount)
    }

    @ViewBuilder
    private func progress(_ stage: SpeakerTranscriptCoordinator.Stage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch stage {
            case .waiting:
                title(String(localized: "speakers.status.waiting"))
                ProgressView().progressViewStyle(.linear)
            case .transcribing:
                title(String(localized: "speakers.status.transcribing"))
                ProgressView().progressViewStyle(.linear)
            case .downloadingModels(let fraction):
                title(String(localized: "speakers.status.downloadingModel"))
                ProgressView(value: fraction)
            case .detecting(let fraction):
                title(String(localized: "speakers.status.detecting"))
                ProgressView(value: fraction)
            }
        }
        .controlSize(.small)
    }

    private func notice(_ text: String) -> some View {
        row(symbol: "exclamationmark.triangle.fill", tint: .orange) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            EmptyView()
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
    }

    private func row<Content: View, Actions: View>(
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        row(
            leading: {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
            },
            content: content,
            actions: actions
        )
    }

    private func row<Leading: View, Content: View, Actions: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            leading()
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
    }
}

/// Three small speech bubbles, a preview of the transcript by speaker.
private struct ConversationSketch: View {
    var body: some View {
        VStack(spacing: 4) {
            bubble(width: 24, color: SpeakerBadge.palette[0], trailing: true)
            bubble(width: 20, color: SpeakerBadge.palette[1], trailing: false)
            bubble(width: 26, color: SpeakerBadge.palette[0], trailing: true)
        }
        .padding(.horizontal, 6)
        .frame(width: 44, height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }

    private func bubble(width: CGFloat, color: Color, trailing: Bool) -> some View {
        Capsule()
            .fill(color.opacity(0.5))
            .frame(width: width, height: 5)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// A speaker's colour with a number or initial, so speakers are never told
/// apart by colour alone.
struct SpeakerBadge: View {
    let speakerID: String
    let name: String?

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    static func color(for speakerID: String) -> Color {
        let number = SpeakerTranscript.speakerNumber(of: speakerID) ?? 1
        return palette[(number - 1) % palette.count]
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Self.color(for: speakerID)))
            .accessibilityHidden(true)
    }

    private var label: String {
        if let initial = name?.trimmingCharacters(in: .whitespaces).first {
            return String(initial).uppercased()
        }
        return (SpeakerTranscript.speakerNumber(of: speakerID) ?? 0).formatted()
    }
}
