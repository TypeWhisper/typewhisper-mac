import Combine
import Foundation

/// An independent content version, not the app/build number. Increment only when
/// the curated highlights in WhatsNewView change for a new release.
enum WhatsNewContent {
    static let version = 1
}

@MainActor
final class WhatsNewCoordinator: ObservableObject {
    nonisolated(unsafe) static var shared: WhatsNewCoordinator?

    private let defaults: UserDefaults
    private let contentVersion: Int
    private var didConsiderLaunch = false
    private var isManualPresentation = false
    private var activitySubscription: AnyCancellable?
    private(set) var isSuppressedForLaunch = false
    private(set) var isPresenting = false
    @Published private(set) var operationInProgress = false
    var dismissPresentation: (() -> Void)?
    var activityDidBecomeIdle: (() -> Void)?

    init(defaults: UserDefaults = .standard, contentVersion: Int = WhatsNewContent.version) {
        self.defaults = defaults
        self.contentVersion = contentVersion

        // New installations already have onboarding. Completing or deferring it
        // must not immediately introduce a second tour, even after a relaunch.
        if !defaults.bool(forKey: UserDefaultsKeys.setupWizardCompleted) {
            acknowledgeCurrentContent()
        }
    }

    var hasUnseenContent: Bool {
        defaults.integer(forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion) < contentVersion
    }

    var shouldDeferAutomaticSheets: Bool {
        // Legacy macOS scenes may create Settings before the delayed launch
        // decision. Once it finishes, later Settings visits retain their normal
        // prompts. Closing the overview itself never requests another sheet.
        operationInProgress || isPresenting
            || (!didConsiderLaunch && (isSuppressedForLaunch || hasUnseenContent))
    }

    /// Called once after launch events have been delivered. A skipped opportunity
    /// stays pending for the next launch; becoming idle never retries it.
    func presentationForLaunch(
        isNormalLaunch: Bool,
        setupWizardRequired: Bool,
        operationInProgress: Bool
    ) -> InitialWindowPresentation {
        guard !didConsiderLaunch else { return .none }
        didConsiderLaunch = true

        // First-time setup keeps its existing priority, including URL and
        // restored-window launches. Only the update overview requires a normal start.
        if setupWizardRequired {
            return .setup
        }

        guard isNormalLaunch, !isSuppressedForLaunch,
              !operationInProgress, !self.operationInProgress else {
            suppressForCurrentLaunch()
            return .none
        }

        let presentation = InitialWindowPresentationPolicy.presentation(
            setupWizardRequired: setupWizardRequired,
            whatsNewPending: hasUnseenContent
        )
        isPresenting = presentation == .whatsNew
        return presentation
    }

    /// Explicitly reopening the highlights is independent of the seen version
    /// and launch eligibility, but ongoing work still takes priority.
    func beginManualPresentation(operationInProgress: Bool = false) -> Bool {
        guard !operationInProgress, !self.operationInProgress else {
            suppressForCurrentLaunch()
            return false
        }
        didConsiderLaunch = true
        isSuppressedForLaunch = true
        isManualPresentation = true
        isPresenting = true
        return true
    }

    /// All activity publishers deliver on the main thread. Keep the app busy
    /// until every operation is idle, including overlapping kinds of work.
    func observeActivity(_ activities: [AnyPublisher<Bool, Never>]) {
        guard let first = activities.first else { return }
        activitySubscription = activities.dropFirst().reduce(first) { combined, activity in
            combined.combineLatest(activity).map { $0 || $1 }.eraseToAnyPublisher()
        }
        .removeDuplicates()
        .sink { [weak self] in self?.updateOperationInProgress($0) }
    }

    func updateOperationInProgress(_ inProgress: Bool) {
        let wasInProgress = operationInProgress
        operationInProgress = inProgress
        if inProgress {
            suppressForCurrentLaunch()
        } else if wasInProgress {
            // Settings may retry a sheet that was deferred specifically by work.
            // The update overview itself is never retried on this transition.
            activityDidBecomeIdle?()
        }
    }

    /// Invoke before an action captures focus or awaits startup work. This also
    /// dismisses an already visible overview without acknowledging unread content.
    func suppressForCurrentLaunch() {
        isSuppressedForLaunch = true
        guard isPresenting else { return }
        isPresenting = false
        isManualPresentation = false
        dismissPresentation?()
    }

    func handleWindowRequest() {
        // Navigation wins over automatic highlights, while a manually opened
        // window remains available. Actual work still closes either presentation.
        if !didConsiderLaunch || (isPresenting && !isManualPresentation) {
            suppressForCurrentLaunch()
        }
    }

    /// Skip, Continue, Escape, window closing and app termination acknowledge it.
    func acknowledgePresentation() {
        guard isPresenting else { return }
        acknowledgeCurrentContent()
        isPresenting = false
        isManualPresentation = false
    }

    private func acknowledgeCurrentContent() {
        let previous = defaults.integer(forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        defaults.set(max(previous, contentVersion), forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
    }
}
