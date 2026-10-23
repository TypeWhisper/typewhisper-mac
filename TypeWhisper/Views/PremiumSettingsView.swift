import SwiftUI

@MainActor
struct CorrectionLearningSettingsView: View {
    @ObservedObject var correctionLearningService: TargetAppCorrectionLearningService
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var learningEnabled = false
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningRequiredObservations) private var requiredObservations = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "wand.and.sparkles",
                accent: .yellow,
                title: String(localized: "premium.hub.learning.title"),
                description: String(localized: "premium.window.learning.description"),
                status: learningEnabled
                    ? String(localized: "premium.hub.status.on")
                    : String(localized: "premium.hub.status.off"),
                statusColor: learningEnabled ? .green : .secondary
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(String(localized: "premium.window.learning.toggle"), isOn: $learningEnabled)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("premium.learning.enabled")
                    Text(String(localized: "premium.window.learning.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Picker(
                        String(localized: "premium.window.learning.repeatCount.label"),
                        selection: $requiredObservations
                    ) {
                        ForEach(TargetAppCorrectionLearningService.requiredObservationChoices, id: \.self) { count in
                            Text(count == 1
                                ? String(localized: "premium.window.learning.repeatCount.immediately")
                                : String.localizedStringWithFormat(
                                    String(localized: "premium.window.learning.repeatCount.afterFormat"), count
                                ))
                                .tag(count)
                        }
                    }
                    .fixedSize()
                    .disabled(!learningEnabled)
                    .accessibilityIdentifier("premium.learning.repeatCount")
                    Text(String(localized: "premium.window.learning.repeatCount.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.learning.lastActivity"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let attempt = correctionLearningService.latestAttempt {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: PremiumCorrectionLearningCopy.outcomeIcon(attempt.outcome))
                                .foregroundStyle(PremiumCorrectionLearningCopy.outcomeColor(attempt.outcome))
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(PremiumCorrectionLearningCopy.outcomeText(attempt.outcome))
                                    .font(.callout.weight(.medium))
                                Text(attempt.timestamp, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if attempt.learnedCorrectionCount > 0 {
                                    Text(String.localizedStringWithFormat(
                                        String(localized: "premium.window.learning.correctionsLearnedFormat"),
                                        attempt.learnedCorrectionCount
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            if let commitSignal = attempt.commitSignal {
                                Text(PremiumCorrectionLearningCopy.commitSignalText(commitSignal))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Label(String(localized: "premium.window.learning.noActivity"), systemImage: "clock")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "premium.window.learning.examplesTitle"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(String(localized: "premium.window.learning.examplesHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(PremiumCorrectionExamples.current.enumerated()), id: \.offset) { _, example in
                        PremiumCorrectionExampleRow(before: example.before, after: example.after)
                    }
                }
            }
        }
    }
}
