import SwiftUI

enum SettingsLayoutMetrics {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cardSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 8
}

struct SettingsPageHeader<Actions: View>: View {
    let title: String
    let summary: String?
    @ViewBuilder let actions: Actions

    init(
        _ title: String,
        summary: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.summary = summary
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    // The page title is the top heading VoiceOver users jump to.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h1)

                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 16)

            actions
                .controlSize(.small)
        }
        // Consistent header height across pages: a trailing accessory (e.g. the
        // Statistics period picker) must not make the bar taller than a
        // title-only header. Summary (two-line) headers still grow past this.
        .frame(minHeight: 28)
        .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if #available(macOS 27, *) {
                Color.clear
            } else {
                Rectangle()
                    .fill(.bar)
            }
        }
    }
}

extension SettingsPageHeader where Actions == EmptyView {
    init(_ title: String, summary: String? = nil) {
        self.init(title, summary: summary) {
            EmptyView()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let selected: Bool
    let accent: Color
    @ViewBuilder let content: Content

    init(
        selected: Bool = false,
        accent: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.selected = selected
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(SettingsLayoutMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                    .stroke(
                        selected ? accent.opacity(0.8) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
    }
}

struct SettingsEmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let action: Action

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            action
        }
        .padding(SettingsLayoutMetrics.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SettingsEmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) {
            EmptyView()
        }
    }
}

/// Makes a card that opens on click reachable from the keyboard: with keyboard navigation on,
/// Tab focuses it like a button, the focus ring follows the card's shape, and Space or Return
/// performs the click action. Apply it before the card's accessibility modifiers so VoiceOver
/// keeps reading the card as one element with its named actions.
struct KeyboardActivatableCard: ViewModifier {
    let cornerRadius: CGFloat
    var isEnabled = true
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            // The focus sits on a layer behind the card rather than on the card itself: a
            // focused control inside the card, such as its switch, then keeps Space and Return,
            // and Tab still reaches the card before its controls.
            content.background {
                Color.clear
                    // The focus ring follows this shape; it has to be set before `focusable`.
                    .contentShape(.focusEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    // `.activate` puts the card in the Tab order only when keyboard navigation
                    // is on, the same rule macOS applies to buttons.
                    .focusable(interactions: .activate)
                    .onKeyPress(keys: [.space, .return], phases: [.down, .repeat]) { press in
                        // A held key repeats; one press opens the card once.
                        if press.phase == .down {
                            action()
                        }
                        return .handled
                    }
                    // The card already offers this action to VoiceOver; the layer would only add
                    // an unnamed element.
                    .accessibilityHidden(true)
            }
        } else {
            content
        }
    }
}

extension View {
    func keyboardActivatableCard(
        cornerRadius: CGFloat = SettingsLayoutMetrics.cardCornerRadius,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardActivatableCard(cornerRadius: cornerRadius, isEnabled: isEnabled, action: action))
    }
}

/// A short, visible confirmation for an action that otherwise changes nothing on
/// screen, such as copying or exporting. VoiceOver hears the same text.
@MainActor
final class ActionConfirmation: ObservableObject {
    struct Message: Equatable {
        let text: String
        let isError: Bool
        /// The control that triggered it, for a confirmation next to one of several rows.
        let source: String
        fileprivate let id = UUID()
    }

    @Published private(set) var message: Message?

    private let duration: Duration
    private let announcementService: AccessibilityAnnouncementService?
    private var resetTask: Task<Void, Never>?

    /// Without a service, the app's shared announcement service is used.
    init(duration: Duration = .seconds(3), announcementService: AccessibilityAnnouncementService? = nil) {
        self.duration = duration
        self.announcementService = announcementService
    }

    func show(_ text: String, source: String = "", isError: Bool = false) {
        resetTask?.cancel()
        let message = Message(text: text, isError: isError, source: source)
        self.message = message

        let service = announcementService ?? ServiceContainer.shared.accessibilityAnnouncementService
        if isError {
            service.announceError(text)
        } else {
            service.announce(text)
        }

        let duration = duration
        resetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, self.message?.id == message.id else { return }
            self.message = nil
        }
    }

    func message(for source: String) -> Message? {
        message?.source == source ? message : nil
    }
}

/// An `ActionConfirmation` message with a checkmark, or a warning sign for an error,
/// so the outcome is not shown by color alone.
struct ActionConfirmationLabel: View {
    let message: ActionConfirmation.Message

    var body: some View {
        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark")
            .font(.caption)
            .foregroundStyle(message.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

/// The entry of an engine picker that uses the default engine, which is chosen on
/// the Dictation page (#1549).
enum DefaultEngineChoice {
    /// Names the engine the entry uses right now, or says that none is available.
    static func title(engineName: String?) -> String {
        guard let engineName = nonEmpty(engineName) else {
            return String(localized: "Default Engine (none available)")
        }
        return String(localized: "Default Engine (\(engineName))")
    }

    /// Shown on the Dictation page while the saved default engine is unavailable;
    /// names the engine dictation uses until it is back, if there is one.
    static func unavailableSavedEngineNotice(savedEngineName: String?, fallbackEngineName: String?) -> String {
        switch (nonEmpty(savedEngineName), nonEmpty(fallbackEngineName)) {
        case let (saved?, fallback?):
            String(localized: "Your default engine, \(saved), is not available right now. Dictation uses \(fallback) until it is available again.")
        case let (nil, fallback?):
            String(localized: "Your default engine is not available right now. Dictation uses \(fallback) until it is available again.")
        case let (saved?, nil):
            String(localized: "Your default engine, \(saved), is not available right now.")
        case (nil, nil):
            String(localized: "Your default engine is not available right now.")
        }
    }

    private static func nonEmpty(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    static var changeTitle: String {
        String(localized: "Change Default Engine")
    }

    static var changeAccessibilityHint: String {
        String(localized: "Opens the Dictation page in Settings.")
    }

    @MainActor
    static func openDictationSettings() {
        SettingsNavigationCoordinator.shared.navigate(to: .dictation)
    }
}

/// Opens the Dictation page from an engine picker while it uses the default engine.
struct DefaultEngineSettingsLink: View {
    var body: some View {
        Button(DefaultEngineChoice.changeTitle) {
            DefaultEngineChoice.openDictationSettings()
        }
        .buttonStyle(.link)
        .font(.caption)
        .accessibilityHint(DefaultEngineChoice.changeAccessibilityHint)
    }
}
