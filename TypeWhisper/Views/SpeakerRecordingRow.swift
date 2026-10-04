import SwiftUI

/// A speaker's part of a recording's speaking time, with the name to show.
struct NamedSpeakerShare: Identifiable, Equatable {
    let id: String
    let name: String
    let fraction: Double

    /// Largest share first; empty when the record has no attributed speech.
    static func shares(of record: TranscriptionRecord) -> [NamedSpeakerShare] {
        guard let transcript = record.speakerTranscript else { return [] }
        let names = record.speakerNames
        return SpeakerTranscriptPresentation.shares(of: SpeakerTranscriptPresentation.turns(of: transcript)).map {
            NamedSpeakerShare(
                id: $0.speakerID,
                name: SpeakerTranscriptPresentation.name(for: $0.speakerID, names: names),
                fraction: $0.fraction
            )
        }
    }
}

/// One recording on the Speakers page, from the moment it is added until
/// its speakers are known.
struct SpeakerRecordingRow: View {
    enum Phase: Equatable {
        case queued
        /// `step` is 1 while transcribing and 2 while detecting speakers.
        case working(step: Int, detail: String, fraction: Double?)
        case failed(String)
        case ready([NamedSpeakerShare])
    }

    let title: String
    let detail: String
    let systemImage: String
    let phase: Phase
    /// Finished while the page was open; gets the check mark.
    var isFresh = false
    var onOpen: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRemove: (() -> Void)?

    @State private var revealed = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tile

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isFresh, isReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: revealed)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                phaseContent
            }

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.purple.opacity(isHovered && onOpen != nil ? 0.1 : 0))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
            guard onOpen != nil else { return }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovered, onOpen != nil { NSCursor.pop() }
        }
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
        .task(id: isReady) {
            guard isReady else {
                revealed = false
                return
            }
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { revealed = true }
            }
        }
    }

    // MARK: - Tile

    private var tile: some View {
        let tint: Color = switch phase {
        case .queued: .secondary
        case .working: .accentColor
        case .failed: .orange
        case .ready: .purple
        }
        return Group {
            switch phase {
            case .queued:
                Image(systemName: "clock")
            case .working:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            case .ready:
                Image(systemName: systemImage)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: 36, height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .accessibilityHidden(true)
    }

    // MARK: - Phase

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .queued:
            Text(String(localized: "speakers.page.queued"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .working(let step, let detail, let fraction):
            working(step: step, detail: detail, fraction: fraction)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let shares):
            if shares.isEmpty {
                Text(String(localized: "speakers.page.noSpeech"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    legend(shares, limit: 4)
                    legend(shares, limit: 3)
                    legend(shares, limit: 2)
                    legend(shares, limit: 1)
                }
                shareBar(shares)
            }
        }
    }

    private func working(step: Int, detail: String, fraction: Double?) -> some View {
        let overall = fraction.map { (Double(step - 1) + min(max($0, 0), 1)) / 2 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                stepLabel(1, String(localized: "speakers.page.step.transcribe"), current: step)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                stepLabel(2, String(localized: "speakers.page.step.detect"), current: step)
                Spacer(minLength: 8)
                if let overall {
                    Text(overall, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            if let overall {
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.3), value: overall)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func stepLabel(_ number: Int, _ title: String, current: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: number < current ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(number < current ? Color.green : number == current ? Color.accentColor : Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(number == current ? .semibold : .regular)
                .foregroundStyle(number == current ? .primary : .secondary)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func legend(_ shares: [NamedSpeakerShare], limit: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(shares.prefix(limit).enumerated()), id: \.element.id) { index, share in
                HStack(spacing: 4) {
                    Circle()
                        .fill(SpeakerBadge.color(for: share.id))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(share.name)
                    Text(share.fraction, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 5)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7).delay(Double(index) * 0.09),
                    value: revealed
                )
            }
            if shares.count > limit {
                Text(verbatim: "+\(shares.count - limit)")
                    .foregroundStyle(.secondary)
                    .opacity(revealed ? 1 : 0)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
    }

    private func shareBar(_ shares: [NamedSpeakerShare]) -> some View {
        let spacing: CGFloat = 2
        return GeometryReader { geometry in
            let available = max(0, geometry.size.width - spacing * CGFloat(shares.count - 1))
            HStack(spacing: spacing) {
                ForEach(shares) { share in
                    Rectangle()
                        .fill(SpeakerBadge.color(for: share.id))
                        .frame(width: available * share.fraction)
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .scaleEffect(x: revealed ? 1 : 0.02, anchor: .leading)
        .opacity(revealed ? 1 : 0)
        .accessibilityHidden(true)
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if let onRetry {
                Button(String(localized: "speakers.action.tryAgain"), action: onRetry)
                    .controlSize(.small)
            }
            if let onCancel {
                iconButton("xmark.circle.fill", label: String(localized: "Cancel"), action: onCancel)
            } else if let onRemove {
                iconButton("xmark.circle.fill", label: String(localized: "Remove \(title)"), action: onRemove)
            } else if onOpen != nil {
                // The label keeps its width while hidden, so hovering does not move the row.
                ZStack(alignment: .trailing) {
                    HStack(spacing: 4) {
                        Text(String(localized: "speakers.page.open"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.purple))
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : 6)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 0 : 1)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 36)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A person TypeWhisper recognizes by voice, with the recordings they appear in.
struct SpeakerPersonCard: View {
    let profile: VoiceProfile
    let onDelete: () -> Void

    @State private var nameDraft = ""
    @State private var isHovered = false
    @FocusState private var isNameFocused: Bool

    private static let shownRecordings = 3

    private var color: Color {
        let palette = SpeakerBadge.palette
        let sum = profile.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    var body: some View {
        let service = ServiceContainer.shared.speakerVoiceProfileService
        let appearances = service.appearances(of: profile.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(profile.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(color.gradient))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    TextField(profile.name, text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .focused($isNameFocused)
                        .onSubmit { commit(service) }
                        .onChange(of: isNameFocused) { _, focused in
                            if !focused { commit(service) }
                        }
                    Text(String.localizedStringWithFormat(
                        String(localized: "premium.window.speakers.profiles.learnedFormat"),
                        SpeakerTranscriptPresentation.timestamp(profile.enrolledSeconds),
                        Int64(appearances.count)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if service.store.isOutdated(profile) {
                        Label(
                            String(localized: "premium.window.speakers.profiles.outdated"),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(String(localized: "premium.window.speakers.profiles.outdatedHelp"))
                    }
                }

                Spacer(minLength: 4)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0.35)
                .help(String(localized: "premium.window.speakers.profiles.delete"))
                .accessibilityLabel(String(localized: "premium.window.speakers.profiles.delete"))
            }

            if !appearances.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(appearances.prefix(Self.shownRecordings)) { appearance in
                        Button {
                            SpeakerNavigation.openInHistory(appearance.recordID)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: appearance.isSuggestion ? "waveform.badge.magnifyingglass" : "waveform")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(appearance.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Text(appearance.date, format: .dateTime.day().month())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if appearances.count > Self.shownRecordings {
                        Text(String.localizedStringWithFormat(
                            String(localized: "speakers.page.people.more"),
                            Int64(appearances.count - Self.shownRecordings)
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(SettingsLayoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onHover { isHovered = $0 }
        .onAppear { nameDraft = profile.name }
        .onChange(of: profile.name) { _, name in
            if !isNameFocused { nameDraft = name }
        }
    }

    private func commit(_ service: SpeakerVoiceProfileService) {
        if nameDraft != profile.name { service.renameProfile(profile.id, to: nameDraft) }
        nameDraft = service.store.profile(withID: profile.id)?.name ?? profile.name
    }
}
