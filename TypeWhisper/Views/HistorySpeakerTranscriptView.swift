import SwiftUI

/// The speaker part of a History record: detection status, or the speaker
/// workspace once a transcript exists.
struct HistorySpeakerTranscriptView: View {
    let record: TranscriptionRecord
    let audioURL: URL?
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    let historyService: HistoryService

    var body: some View {
        if let stage = coordinator.stages[record.id] {
            progress(stage)
        } else if record.speakerTranscriptData != nil {
            SpeakerWorkspaceView(
                record: record,
                audioURL: audioURL,
                coordinator: coordinator,
                historyService: historyService
            )
            // A new record gets its own workspace state and player.
            .id(record.id)
        } else {
            failure
        }
    }

    // MARK: - Status

    private func progress(_ stage: SpeakerTranscriptCoordinator.Stage) -> some View {
        VStack(spacing: 12) {
            switch stage {
            case .waiting:
                ProgressView()
                Text(String(localized: "speakers.status.waiting"))
            case .transcribing:
                ProgressView()
                Text(String(localized: "speakers.status.transcribing"))
            case .downloadingModels(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
                Text(String(localized: "speakers.status.downloadingModel"))
            case .detecting(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: 260)
                Text(String(localized: "speakers.status.detecting"))
            }
            Button(String(localized: "Cancel")) {
                coordinator.cancel(recordID: record.id)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failure: some View {
        ContentUnavailableView {
            Label(String(localized: "speakers.status.failed"), systemImage: "person.2.slash")
        } description: {
            if let reason = failureReason {
                Text(reason)
            }
        } actions: {
            if coordinator.startError(for: record) == .premiumRequired {
                Button(String(localized: "speakers.premium.open")) {
                    SettingsNavigationCoordinator.shared.navigate(to: .premium)
                }
            } else if coordinator.startError(for: record) == nil {
                Button(String(localized: "speakers.action.tryAgain")) {
                    coordinator.start(recordID: record.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureReason: String? {
        switch coordinator.startError(for: record) {
        case .premiumRequired: String(localized: "speakers.premium.required")
        case .providerUnavailable: String(localized: "speakers.status.providerUnavailable")
        case .audioMissing: String(localized: "speakers.status.audioMissing")
        case .timingMissing: String(localized: "speakers.status.timingMissing")
        case nil: nil
        }
    }
}

/// A speaker's colour with a number or initial, so speakers are never told
/// apart by colour alone.
struct SpeakerBadge: View {
    let speakerID: String
    let name: String?

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

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
