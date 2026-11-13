import AppKit
import Combine
import SwiftUI

/// Whether Ask History is unlocked: a commercial license or a Premium account.
enum AskHistoryPremiumAccess {
    static func isGranted(hasCommercialLicense: Bool, hasPremiumEntitlement: Bool) -> Bool {
        hasCommercialLicense || hasPremiumEntitlement
    }
}

/// What the panel needs besides the session, so tests can stand in for it.
@MainActor
struct AskHistoryPanelEnvironment {
    var hasPremiumAccess: () -> Bool
    /// Cloud providers Ask History would try, by ID and name.
    var cloudProviders: () -> [(id: String, name: String)]
    var prewarm: () -> Void
    /// Opens a record in History, at a time in its speaker transcript when given.
    var openRecord: (UUID, TimeInterval?) -> Void
    var openLanguageModelSettings: () -> Void
    var openPremium: () -> Void
    /// False while the organization turns Ask History off (`AllowHistoryAsk`).
    var isAllowedByPolicy: () -> Bool = { true }
    /// Fires when a license, a Premium account or the managed policy may have changed.
    var accessChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    var defaults: UserDefaults = .standard
}

/// The state of the panel around the session: the text being typed, Premium,
/// and the cloud consent a question may wait for.
@MainActor
final class AskHistoryPanelModel: ObservableObject {
    @Published var draft = ""
    /// Cloud providers the question waits for the user to allow.
    @Published private(set) var consentProviders: [(id: String, name: String)] = []
    @Published private(set) var hasPremiumAccess: Bool
    @Published private(set) var isTurnedOffByPolicy: Bool

    let session: AskHistorySession
    private let environment: AskHistoryPanelEnvironment
    private var pendingQuestion: String?
    private var accessSubscription: AnyCancellable?

    init(session: AskHistorySession, environment: AskHistoryPanelEnvironment) {
        self.session = session
        self.environment = environment
        hasPremiumAccess = environment.hasPremiumAccess()
        isTurnedOffByPolicy = !environment.isAllowedByPolicy()
        // Read after the change, which the publishers announce before it happens.
        accessSubscription = environment.accessChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshAccess() }
    }

    var needsConsent: Bool { !consentProviders.isEmpty }

    func refreshAccess() {
        let isTurnedOff = !environment.isAllowedByPolicy()
        if isTurnedOff != isTurnedOffByPolicy { isTurnedOffByPolicy = isTurnedOff }
        let hasAccess = environment.hasPremiumAccess()
        if hasAccess != hasPremiumAccess { hasPremiumAccess = hasAccess }
        // A question that has not reached a provider yet must not send anything now.
        if !canAsk {
            session.stop()
            declineCloudProviders()
        }
    }

    /// Premium and the organization both allow a question.
    var canAsk: Bool { hasPremiumAccess && !isTurnedOffByPolicy }

    private var allowedProviders: Set<String> {
        Set(environment.defaults.stringArray(forKey: UserDefaultsKeys.askHistoryCloudConsents) ?? [])
    }

    /// Sends the typed question, after the consent for cloud providers that
    /// have none yet.
    func send(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !question.isEmpty, !session.isWorking else { return }
        let allowed = allowedProviders
        let missing = environment.cloudProviders().filter { !allowed.contains($0.id) }
        draft = ""
        guard missing.isEmpty else {
            pendingQuestion = question
            consentProviders = missing
            return
        }
        session.ask(question)
    }

    func allowCloudProviders() {
        var allowed = environment.defaults.stringArray(forKey: UserDefaultsKeys.askHistoryCloudConsents) ?? []
        allowed += consentProviders.map(\.id).filter { !allowed.contains($0) }
        environment.defaults.set(allowed, forKey: UserDefaultsKeys.askHistoryCloudConsents)
        // The list may have changed while the user read the prompt.
        let stillMissing = environment.cloudProviders().filter { !allowedProviders.contains($0.id) }
        guard stillMissing.isEmpty else {
            consentProviders = stillMissing
            return
        }
        consentProviders = []
        if let pendingQuestion {
            self.pendingQuestion = nil
            session.ask(pendingQuestion)
        }
    }

    func declineCloudProviders() {
        draft = pendingQuestion ?? draft
        pendingQuestion = nil
        consentProviders = []
    }

    func startNewConversation() {
        declineCloudProviders()
        draft = ""
        session.startNewConversation()
    }

    /// Starts a new conversation about another part of History, unless the
    /// current one already asks about it.
    func ask(about scope: AskHistoryConversationScope) {
        guard scope != session.scope else { return }
        startNewConversation()
        session.scope = scope
        objectWillChange.send()
    }

    func openRecord(_ id: UUID, at seconds: TimeInterval?) { environment.openRecord(id, seconds) }
    func openLanguageModelSettings() { environment.openLanguageModelSettings() }
    func openPremium() { environment.openPremium() }
}

/// Shows Ask History in a floating panel that takes the keyboard without
/// activating TypeWhisper, so the app the user came from stays frontmost.
@MainActor
final class AskHistoryPanelController {
    static let width: CGFloat = 640
    static let compactHeight: CGFloat = 300
    /// A conversation older than this starts over when the panel opens.
    static let conversationTimeout: TimeInterval = 15 * 60

    let model: AskHistoryPanelModel
    private let environment: AskHistoryPanelEnvironment
    private let now: () -> Date
    private var panel: AskHistoryPanel?
    private var turnsSubscription: AnyCancellable?
    private var accessSubscription: AnyCancellable?

    init(session: AskHistorySession, environment: AskHistoryPanelEnvironment, now: @escaping () -> Date = Date.init) {
        model = AskHistoryPanelModel(session: session, environment: environment)
        self.environment = environment
        self.now = now
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Opens the panel for a conversation about `scope`, such as one recording.
    func show(scope: AskHistoryConversationScope) {
        model.ask(about: scope)
        show()
    }

    func show() {
        model.refreshAccess()
        let session = model.session
        if !session.turns.isEmpty, now().timeIntervalSince(session.updatedAt) > Self.conversationTimeout {
            model.startNewConversation()
        }
        // Also when Premium is unlocked while the panel shows the locked state.
        accessSubscription = model.$hasPremiumAccess
            .combineLatest(model.$isTurnedOffByPolicy)
            .map { $0 && !$1 }
            .removeDuplicates()
            .filter { $0 }
            .sink { [environment] _ in
                environment.prewarm()
                Task { await session.prepare() }
            }

        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel, expanded: !session.turns.isEmpty, keepingTop: false)
        panel.makeKeyAndOrderFront(nil)
        turnsSubscription = session.$turns
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self, weak panel] expanded in
                guard let self, let panel else { return }
                self.resize(panel, expanded: expanded, keepingTop: true)
            }
    }

    /// Hides the panel and keeps the conversation.
    func hide() {
        turnsSubscription = nil
        accessSubscription = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> AskHistoryPanel {
        let panel = AskHistoryPanel()
        // Borderless panels have no visible title; VoiceOver still names the window by it.
        panel.title = String(localized: "askHistory.title")
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onNewConversation = { [weak self] in self?.model.startNewConversation() }
        panel.onStop = { [weak self] in self?.model.session.stop() }
        let hosting = NSHostingView(rootView: AskHistoryPanelView(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// Compact with an empty conversation, up to 60 % of the screen with turns.
    private func resize(_ panel: AskHistoryPanel, expanded: Bool, keepingTop: Bool) {
        let screen = keepingTop ? (panel.screen ?? AskHistoryPanel.activeScreen()) : AskHistoryPanel.activeScreen()
        guard let visible = screen?.visibleFrame else { return }
        let height = expanded ? max(Self.compactHeight, (visible.height * 0.6).rounded()) : Self.compactHeight
        // In the upper third of the screen; a grown panel keeps its top edge.
        let top = keepingTop && panel.isVisible ? panel.frame.maxY : visible.maxY - (visible.height * 0.12).rounded()
        let x = keepingTop && panel.isVisible ? panel.frame.minX : visible.midX - Self.width / 2
        panel.setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
    }
}

private final class AskHistoryPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onNewConversation: (() -> Void)?
    var onStop: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: AskHistoryPanelController.width, height: AskHistoryPanelController.compactHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// ⌘N starts a new conversation and ⌘. stops, wherever the keyboard focus is.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.type == .keyDown, modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "n":
                onNewConversation?()
                return true
            case ".":
                onStop?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Content

struct AskHistoryPanelView: View {
    @ObservedObject var model: AskHistoryPanelModel
    @ObservedObject private var session: AskHistorySession
    @FocusState private var isInputFocused: Bool

    init(model: AskHistoryPanelModel) {
        self.model = model
        session = model.session
    }

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            if case .records(let ids, let title) = session.scope {
                AskHistoryScopeChip(title: title, count: ids.count) { model.ask(about: .all) }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .onAppear { isInputFocused = true }
    }

    private var inputBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "askHistory.input.placeholder"), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .disabled(!model.canAsk || model.needsConsent)
                .onSubmit { model.send() }
            if session.isWorking {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .help(String(localized: "askHistory.stop"))
                .accessibilityLabel(String(localized: "askHistory.stop"))
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.draft.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canAsk)
                .help(String(localized: "askHistory.send"))
                .accessibilityLabel(String(localized: "askHistory.send"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.isTurnedOffByPolicy {
            AskHistoryManagedView()
        } else if !model.hasPremiumAccess {
            AskHistoryLockedView(onUnlock: model.openPremium)
        } else if model.needsConsent {
            AskHistoryConsentView(
                providers: model.consentProviders.map(\.name),
                onAllow: model.allowCloudProviders,
                onDecline: model.declineCloudProviders
            )
        } else if session.turns.isEmpty {
            AskHistoryEmptyView { model.send($0) }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(session.turns) { turn in
                            AskHistoryTurnView(turn: turn, model: model).id(turn.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: session.turns.count) {
                    if let last = session.turns.last { proxy.scrollTo(last.id, anchor: .top) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(String(localized: "askHistory.footer.newConversation"))
            Text(String(localized: "askHistory.footer.hide"))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The recordings a conversation asks about, with a button back to all of History.
private struct AskHistoryScopeChip: View {
    let title: String
    let count: Int
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: count == 1 ? "waveform" : "square.stack")
                .accessibilityHidden(true)
            Text(count == 1 ? title : String(format: String(localized: "askHistory.scope.records"), count))
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(String(localized: "askHistory.scope.clear"))
            .accessibilityLabel(String(localized: "askHistory.scope.clear"))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct AskHistoryEmptyView: View {
    let onAsk: (String) -> Void

    private let suggestions = [
        String(localized: "askHistory.suggestion.today"),
        String(localized: "askHistory.suggestion.lastMeeting"),
        String(localized: "askHistory.suggestion.tasks"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "askHistory.empty.message"))
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    onAsk(suggestion)
                } label: {
                    Label(suggestion, systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.link)
            }
        }
        .padding(16)
    }
}

private struct AskHistoryManagedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "askHistory.managed.title"), systemImage: "building.2")
                .font(.headline)
            Text(String(localized: "askHistory.managed.message"))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

private struct AskHistoryLockedView: View {
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "askHistory.locked.title"), systemImage: "lock.fill")
                .font(.headline)
            Text(String(localized: "askHistory.locked.message"))
                .foregroundStyle(.secondary)
            Button(String(localized: "askHistory.locked.unlock"), action: onUnlock)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

private struct AskHistoryConsentView: View {
    let providers: [String]
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "askHistory.consent.title"), systemImage: "icloud.and.arrow.up")
                .font(.headline)
            Text(String(
                format: String(localized: "askHistory.consent.message"),
                ListFormatter.localizedString(byJoining: providers)
            ))
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "askHistory.consent.allow"), action: onAllow)
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "askHistory.consent.decline"), action: onDecline)
            }
        }
        .padding(16)
    }
}

/// A source as the panel lists it.
private struct AskHistorySourceRow: Identifiable {
    let id: Int
    let number: Int?
    let recordID: UUID
    let title: String
    let date: Date
    let excerpt: String
    let startSeconds: Double?
    let isCited: Bool
}

private struct AskHistoryTurnView: View {
    let turn: AskHistorySessionTurn
    @ObservedObject var model: AskHistoryPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .font(.headline)
                .textSelection(.enabled)
            status
            if let answer = turn.answer {
                Text(answer.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if answer.omittedRecordCount > 0 {
                    Text(String.localizedStringWithFormat(String(localized: "askHistory.answer.omitted"), Int64(answer.omittedRecordCount)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(String(format: String(localized: "askHistory.answer.provider"), answer.providerName))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            sources
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var status: some View {
        switch turn.stage {
        case .preparingIndex:
            progress(String(localized: "askHistory.stage.preparing"))
        case .searching:
            progress(String(localized: "askHistory.stage.searching"))
        case .summarizing(let number, let count):
            progress(String(format: String(localized: "askHistory.stage.summarizing"), number, count))
        case .answering:
            progress(String(localized: "askHistory.stage.answering"))
        case .answered:
            EmptyView()
        case .needsLanguageModel:
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "askHistory.needsLanguageModel.message"))
                    .foregroundStyle(.secondary)
                Button(String(localized: "askHistory.needsLanguageModel.settings"), action: model.openLanguageModelSettings)
            }
        case .stopped:
            Text(String(localized: "askHistory.stage.stopped"))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    /// The sources the answer cites, or all it was given when it cites none.
    /// Without an answer, what the search found.
    private var rows: [AskHistorySourceRow] {
        if let answer = turn.answer {
            let order = answer.citedSources.isEmpty ? answer.sources.indices.map { $0 + 1 } : answer.citedSources
            return order.map { number in
                let source = answer.sources[number - 1]
                return AskHistorySourceRow(
                    id: number, number: number, recordID: source.recordID,
                    title: source.title ?? source.origin ?? String(localized: "askHistory.source.untitled"),
                    date: source.recordedAt, excerpt: source.text, startSeconds: source.startSeconds,
                    isCited: answer.citedSources.contains(number)
                )
            }
        }
        return turn.found.enumerated().map { offset, hit in
            AskHistorySourceRow(
                id: offset, number: nil, recordID: hit.recordID,
                title: hit.title ?? hit.appName ?? String(localized: "askHistory.source.untitled"),
                date: hit.recordedAt, excerpt: hit.passage.text, startSeconds: hit.passage.startSeconds,
                isCited: false
            )
        }
    }

    @ViewBuilder
    private var sources: some View {
        let rows = rows
        if !rows.isEmpty, turn.answer != nil || turn.stage == .needsLanguageModel {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "askHistory.sources.title"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    Button {
                        model.openRecord(row.recordID, at: row.startSeconds)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let number = row.number {
                                Text("[\(number)]")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(row.isCited ? Color.accentColor : Color.secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.title).fontWeight(.medium)
                                    Text(row.date, format: .dateTime.day().month().year().hour().minute())
                                        .foregroundStyle(.secondary)
                                }
                                Text(row.excerpt)
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.number.map { "\($0). \(row.title)" } ?? row.title)
                    .accessibilityHint(String(localized: "askHistory.source.openHint"))
                }
                let more = turn.found.count - rows.count
                if more > 0 {
                    Text(String.localizedStringWithFormat(String(localized: "askHistory.sources.more"), Int64(more)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
