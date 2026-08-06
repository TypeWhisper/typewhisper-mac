import AppKit
import AVFoundation
import Combine
import Foundation
import os

private let calendarMeetingAutomationLogger = Logger(
    subsystem: AppConstants.loggerSubsystem,
    category: "CalendarMeetingAutomation"
)

func requestCalendarMeetingCalendarAccess(
    using provider: any CalendarMeetingEventProviding
) async -> CalendarMeetingCalendarAccessRequestOutcome {
    do {
        let granted = try await provider.requestFullAccess()
        let authorization = await provider.authorizationStatus()
        let failure: CalendarMeetingCalendarAccessRequestFailure?
        if authorization == .fullAccess {
            failure = nil
        } else if granted || authorization == .notDetermined {
            failure = .notCompleted
        } else {
            failure = nil
        }
        return CalendarMeetingCalendarAccessRequestOutcome(
            authorization: authorization,
            failure: failure
        )
    } catch {
        let authorization = await provider.authorizationStatus()
        let error = error as NSError
        return CalendarMeetingCalendarAccessRequestOutcome(
            authorization: authorization,
            failure: .system(domain: error.domain, code: error.code)
        )
    }
}

enum CalendarMeetingBrowserURLResolution: Equatable, Sendable {
    case unavailable
    case nonMeeting
    case meeting(CalendarMeetingCanonicalLink)
}

@MainActor
final class CalendarMeetingAutomationController: ObservableObject {
    nonisolated static func shouldActivateOSServices(
        hasPremiumAccess: Bool,
        startMode: CalendarMeetingStartMode
    ) -> Bool {
        hasPremiumAccess && startMode != .off
    }

    nonisolated static func shouldResolveBrowserURL(for process: MeetingAudioProcess) -> Bool {
        (process.isRunningInput || process.isRunningOutput)
            && SupportedMeetingBrowser.supportsAutomaticURLResolution(process.bundleIdentifier)
    }

    nonisolated static func browserURLResolution(
        for resolvedURL: URL?
    ) -> CalendarMeetingBrowserURLResolution {
        guard let resolvedURL else { return .unavailable }
        guard let link = MeetingLinkParser().parse(url: resolvedURL) else {
            return .nonMeeting
        }
        return .meeting(link)
    }

    nonisolated static func aggregatedBrowserProcesses(
        _ processes: [MeetingAudioProcess]
    ) -> [MeetingAudioProcess] {
        let canonicalProcesses = processes.compactMap { process -> MeetingAudioProcess? in
            guard let bundleIdentifier = BrowserAudioProcessAttribution
                .canonicalBrowserBundleIdentifier(for: process.bundleIdentifier) else {
                return nil
            }
            return MeetingAudioProcess(
                audioObjectID: process.audioObjectID,
                processID: process.processID,
                bundleIdentifier: bundleIdentifier,
                isRunningInput: process.isRunningInput,
                isRunningOutput: process.isRunningOutput
            )
        }
        return Dictionary(grouping: canonicalProcesses) { $0.bundleIdentifier }
            .compactMap { bundleIdentifier, groupedProcesses in
                guard SupportedMeetingBrowser.supportsAutomaticURLResolution(
                    bundleIdentifier
                ),
                let representative = groupedProcesses.min(by: {
                    if $0.processID != $1.processID {
                        return $0.processID < $1.processID
                    }
                    return $0.audioObjectID < $1.audioObjectID
                }) else {
                    return nil
                }
                return MeetingAudioProcess(
                    audioObjectID: representative.audioObjectID,
                    processID: representative.processID,
                    bundleIdentifier: bundleIdentifier,
                    isRunningInput: groupedProcesses.contains { $0.isRunningInput },
                    isRunningOutput: groupedProcesses.contains { $0.isRunningOutput }
                )
            }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    nonisolated static func canUseAutoStopNotifications(
        authorization: CalendarMeetingNotificationAuthorization
    ) -> Bool {
        authorization.permitsAutoStop
    }

    nonisolated static func shouldStartCalendarAccessRequest(
        hasPremiumAccess: Bool,
        startMode: CalendarMeetingStartMode,
        isRequestInFlight: Bool
    ) -> Bool {
        hasPremiumAccess && startMode != .off && !isRequestInFlight
    }

    nonisolated static func shouldRequestNotifications(
        hasPremiumAccess: Bool,
        startMode: CalendarMeetingStartMode,
        calendarAuthorization: CalendarMeetingCalendarAuthorization
    ) -> Bool {
        hasPremiumAccess
            && startMode != .off
            && calendarAuthorization == .fullAccess
    }

    nonisolated static func automationUserAction(
        for response: CalendarMeetingNotificationResponse
    ) -> CalendarMeetingAutomationUserAction? {
        switch response {
        case .armStart(let digest):
            .armOccurrence(digest)
        case .suppress(let digest):
            .suppressOccurrence(digest)
        case .continueRecording, .openPremiumSettings:
            nil
        }
    }

    typealias EventProviderFactory = @MainActor () -> any CalendarMeetingEventProviding
    typealias AudioCollectorFactory = @MainActor () -> any MeetingAudioActivityCollecting
    typealias CameraCollectorFactory = @MainActor () -> any MeetingCameraActivityCollecting
    typealias BrowserResolverFactory = @MainActor () -> any BrowserURLResolving
    typealias NotificationServiceFactory = @MainActor () -> any CalendarMeetingNotifying

    @Published private(set) var hasPremiumAccess: Bool
    @Published private(set) var startMode: CalendarMeetingStartMode
    @Published private(set) var autoStopEnabled: Bool
    @Published private(set) var selectedCalendarIDs: Set<String>
    @Published private(set) var enabledProviders: Set<MeetingProvider>
    @Published private(set) var calendars: [CalendarMeetingCalendar] = []
    @Published private(set) var calendarAuthorization: CalendarMeetingCalendarAuthorization = .notDetermined
    @Published private(set) var notificationAuthorization: CalendarMeetingNotificationAuthorization = .notDetermined
    @Published private(set) var isAutomationActive = false
    @Published private(set) var isCalendarAccessRequestInFlight = false
    @Published private(set) var calendarAccessRequestFailure:
        CalendarMeetingCalendarAccessRequestFailure?

    var canEnableAutoStop: Bool {
        Self.canUseAutoStopNotifications(authorization: notificationAuthorization)
    }

    private struct ActiveCalendarRecordingContext {
        let handle: CalendarMeetingRecordingHandle
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
    }

    private let licenseService: LicenseService
    private let premiumAccountService: PremiumAccountService
    private let recorderViewModel: AudioRecorderViewModel
    private let dictationViewModel: DictationViewModel
    private let countdownModel: CalendarMeetingCountdownModel
    private let defaults: UserDefaults
    private let eventProviderFactory: EventProviderFactory
    private let audioCollectorFactory: AudioCollectorFactory
    private let cameraCollectorFactory: CameraCollectorFactory
    private let browserResolverFactory: BrowserResolverFactory
    private let notificationServiceFactory: NotificationServiceFactory
    private let premiumAccessProvider: @MainActor () -> Bool
    private let nowProvider: @MainActor () -> Date

    private var policy = CalendarMeetingAutomationPolicy()
    private var currentOccurrences: [CalendarMeetingOccurrence] = []
    private var eventProvider: (any CalendarMeetingEventProviding)?
    private var audioCollector: (any MeetingAudioActivityCollecting)?
    private var cameraCollector: (any MeetingCameraActivityCollecting)?
    private var browserResolver: (any BrowserURLResolving)?
    private var notificationService: (any CalendarMeetingNotifying)?
    private var activeCalendarRecording: ActiveCalendarRecordingContext?
    private var activeAutoStopWarningDigest: String?
    private var activeAutoStopWarningHandle: CalendarMeetingRecordingHandle?
    private var browserMeetingIdentityByBundleIdentifier:
        [String: CalendarMeetingCanonicalLink] = [:]
    private var calendarAutoStopTrackingActive = false
    private var notificationRouterInstalled = false
    private var initialized = false
    private var refreshGeneration = 0
    private var activityGeneration = 0
    private var cameraActivityGeneration = 0
    private var recordingStartGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var horizonRefreshTask: Task<Void, Never>?
    private var eventChangesTask: Task<Void, Never>?
    private var eventChangesSessionID: UUID?
    private var collectorTask: Task<Void, Never>?
    private var collectorSessionID: UUID?
    private var collectorShouldBeRunning = false
    private var cameraCollectorTask: Task<Void, Never>?
    private var cameraCollectorSessionID: UUID?
    private var cameraCollectorShouldBeRunning = false
    private var policyTimerTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var calendarAccessRequestTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var environmentObserverTokens: [NSObjectProtocol] = []

    init(
        licenseService: LicenseService,
        premiumAccountService: PremiumAccountService,
        recorderViewModel: AudioRecorderViewModel,
        dictationViewModel: DictationViewModel,
        countdownModel: CalendarMeetingCountdownModel,
        defaults: UserDefaults = .standard,
        eventProviderFactory: @escaping EventProviderFactory = { EventKitCalendarMeetingProvider() },
        audioCollectorFactory: @escaping AudioCollectorFactory = { MeetingAudioActivityCollector() },
        cameraCollectorFactory: @escaping CameraCollectorFactory = {
            MeetingCameraActivityCollector()
        },
        browserResolverFactory: @escaping BrowserResolverFactory = { BrowserURLResolver() },
        notificationServiceFactory: @escaping NotificationServiceFactory = {
            CalendarMeetingNotificationService()
        },
        premiumAccessProvider: (@MainActor () -> Bool)? = nil,
        nowProvider: @escaping @MainActor () -> Date = Date.init
    ) {
        self.licenseService = licenseService
        self.premiumAccountService = premiumAccountService
        self.recorderViewModel = recorderViewModel
        self.dictationViewModel = dictationViewModel
        self.countdownModel = countdownModel
        self.defaults = defaults
        self.eventProviderFactory = eventProviderFactory
        self.audioCollectorFactory = audioCollectorFactory
        self.cameraCollectorFactory = cameraCollectorFactory
        self.browserResolverFactory = browserResolverFactory
        self.notificationServiceFactory = notificationServiceFactory
        self.nowProvider = nowProvider

        let accessProvider = premiumAccessProvider ?? {
            CalendarMeetingPremiumAccess.isGranted(
                hasCommercialLicense: licenseService.hasCommercialLicense,
                hasPremiumEntitlement: premiumAccountService.hasPremiumEntitlement
            )
        }
        self.premiumAccessProvider = accessProvider
        hasPremiumAccess = accessProvider()
        startMode = CalendarMeetingStartMode(
            rawValue: defaults.string(forKey: UserDefaultsKeys.calendarMeetingStartMode) ?? ""
        ) ?? .off
        autoStopEnabled = defaults.bool(forKey: UserDefaultsKeys.calendarMeetingAutoStopEnabled)
        selectedCalendarIDs = Set(
            defaults.stringArray(forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs) ?? []
        )
        if defaults.object(forKey: UserDefaultsKeys.calendarMeetingEnabledProviderIDs) == nil {
            enabledProviders = Set(MeetingProvider.allCases)
        } else {
            enabledProviders = Set(
                (defaults.stringArray(forKey: UserDefaultsKeys.calendarMeetingEnabledProviderIDs) ?? [])
                    .compactMap(MeetingProvider.init(rawValue:))
            )
        }
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true

        licenseService.objectWillChange
            .merge(with: premiumAccountService.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.entitlementDidChange()
                }
            }
            .store(in: &cancellables)

        recorderViewModel.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorderOrDictationStateDidChange()
            }
            .store(in: &cancellables)

        recorderViewModel.$micEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorderOrDictationStateDidChange()
            }
            .store(in: &cancellables)

        recorderViewModel.$systemAudioEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorderOrDictationStateDidChange()
            }
            .store(in: &cancellables)

        recorderViewModel.$retranscribingRecordingURL
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorderOrDictationStateDidChange()
            }
            .store(in: &cancellables)

        dictationViewModel.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recorderOrDictationStateDidChange()
            }
            .store(in: &cancellables)

        observeEnvironmentChanges()
        entitlementDidChange()
    }

    func installNotificationRouterIfNeeded() {
        guard CalendarMeetingNotificationService.shouldInstallRouter(defaults: defaults) else { return }
        ensureNotificationRouterInstalled()
    }

    func setStartMode(_ mode: CalendarMeetingStartMode) {
        guard mode != startMode else { return }
        invalidatePendingRecordingStart()
        if activeCalendarRecording != nil {
            calendarAutoStopTrackingActive = false
            dismissAutoStopWarning()
        }
        if mode == .off {
            persistStartMode(.off)
            requestRefresh()
            return
        }
        persistStartMode(mode)
        requestRefresh()
    }

    func requestCalendarAccess() {
        let hasAccess = premiumAccessProvider()
        guard Self.shouldStartCalendarAccessRequest(
            hasPremiumAccess: hasAccess,
            startMode: startMode,
            isRequestInFlight: isCalendarAccessRequestInFlight
        ) else {
            if !hasAccess {
                entitlementDidChange()
            }
            return
        }

        calendarAccessRequestFailure = nil
        isCalendarAccessRequestInFlight = true
        let provider = eventProviderInstance()
        calendarAccessRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await requestCalendarMeetingCalendarAccess(using: provider)
            guard !Task.isCancelled else { return }

            self.calendarAccessRequestTask = nil
            self.isCalendarAccessRequestInFlight = false
            self.calendarAuthorization = outcome.authorization
            self.calendarAccessRequestFailure = outcome.failure

            if let failure = outcome.failure {
                switch failure {
                case .notCompleted:
                    calendarMeetingAutomationLogger.error(
                        "Calendar access request did not complete and authorization remains unavailable"
                    )
                case .system(let domain, let code):
                    calendarMeetingAutomationLogger.error(
                        "Calendar access request failed: \(domain, privacy: .public) code \(code)"
                    )
                }
            }

            guard Self.shouldRequestNotifications(
                hasPremiumAccess: self.premiumAccessProvider(),
                startMode: self.startMode,
                calendarAuthorization: outcome.authorization
            ) else {
                self.requestRefresh()
                return
            }

            await self.initializeCalendarSelectionIfNeeded(provider: provider)
            let notificationService = self.notificationServiceInstance()
            self.ensureNotificationRouterInstalled()
            self.notificationAuthorization = await notificationService
                .configureAndRequestAuthorization()
            self.disableAutoStopIfNotificationsUnavailable()
            self.requestRefresh()
        }
    }

    func dismissCalendarAccessRequestFailure() {
        calendarAccessRequestFailure = nil
    }

    func setAutoStopEnabled(_ enabled: Bool) {
        guard !enabled || canEnableAutoStop else { return }
        guard autoStopEnabled != enabled else { return }
        autoStopEnabled = enabled
        if !enabled {
            calendarAutoStopTrackingActive = false
            dismissAutoStopWarning()
        }
        defaults.set(enabled, forKey: UserDefaultsKeys.calendarMeetingAutoStopEnabled)
        applyPolicyConfiguration(now: nowProvider())
    }

    func setCalendar(_ calendarID: String, enabled: Bool) {
        invalidatePendingRecordingStart()
        if activeCalendarRecording != nil {
            calendarAutoStopTrackingActive = false
            dismissAutoStopWarning()
        }
        if enabled {
            selectedCalendarIDs.insert(calendarID)
        } else {
            selectedCalendarIDs.remove(calendarID)
        }
        defaults.set(
            selectedCalendarIDs.sorted(),
            forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs
        )
        defaults.set(
            true,
            forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized
        )
        requestRefresh()
    }

    func setProvider(_ provider: MeetingProvider, enabled: Bool) {
        invalidatePendingRecordingStart()
        if activeCalendarRecording != nil {
            calendarAutoStopTrackingActive = false
            dismissAutoStopWarning()
        }
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
        }
        defaults.set(
            enabledProviders.map(\.rawValue).sorted(),
            forKey: UserDefaultsKeys.calendarMeetingEnabledProviderIDs
        )
        requestRefresh()
    }

    func refreshPermissionsAndEvents() {
        requestRefresh()
    }

    func openCalendarPrivacySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    func openNotificationSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    func handleWake() {
        recorderOrDictationStateDidChange()
        requestRefresh()
    }

    func handleApplicationBecameActive() {
        recorderOrDictationStateDidChange()
        requestRefresh()
    }

    func shutdown() {
        cancellables.removeAll()
        initialized = false
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        horizonRefreshTask?.cancel()
        horizonRefreshTask = nil
        eventChangesTask?.cancel()
        eventChangesTask = nil
        eventChangesSessionID = nil
        collectorTask?.cancel()
        collectorTask = nil
        collectorSessionID = nil
        collectorShouldBeRunning = false
        activityGeneration += 1
        cameraCollectorTask?.cancel()
        cameraCollectorTask = nil
        cameraCollectorSessionID = nil
        cameraCollectorShouldBeRunning = false
        cameraActivityGeneration += 1
        policyTimerTask?.cancel()
        policyTimerTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        calendarAccessRequestTask?.cancel()
        calendarAccessRequestTask = nil
        isCalendarAccessRequestInFlight = false
        calendarAccessRequestFailure = nil
        if let activeAutoStopWarningDigest, let notificationService {
            notificationService.removeAutoStopWarning(
                occurrenceDigest: activeAutoStopWarningDigest
            )
        }
        activeAutoStopWarningDigest = nil
        activeAutoStopWarningHandle = nil
        countdownModel.dismissAll()
        invalidatePendingRecordingStart()
        if let audioCollector {
            Task { await audioCollector.stopCollecting() }
        }
        self.audioCollector = nil
        if let cameraCollector {
            Task { await cameraCollector.stopCollecting() }
        }
        self.cameraCollector = nil
        eventProvider = nil
        browserResolver = nil
        browserMeetingIdentityByBundleIdentifier.removeAll()
        calendarAutoStopTrackingActive = false
        currentOccurrences = []
        policy = CalendarMeetingAutomationPolicy()
        environmentObserverTokens.forEach(NotificationCenter.default.removeObserver)
        environmentObserverTokens.removeAll()
    }

    private func entitlementDidChange() {
        let access = premiumAccessProvider()
        guard access != hasPremiumAccess else {
            requestRefresh()
            return
        }
        invalidatePendingRecordingStart()
        if !access {
            calendarAutoStopTrackingActive = false
            dismissAutoStopWarning()
        }
        hasPremiumAccess = access
        requestRefresh()
    }

    private func persistStartMode(_ mode: CalendarMeetingStartMode) {
        startMode = mode
        defaults.set(mode.rawValue, forKey: UserDefaultsKeys.calendarMeetingStartMode)
    }

    private func requestRefresh() {
        horizonRefreshTask?.cancel()
        horizonRefreshTask = nil
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.performRefresh(generation: generation)
        }
    }

    private func performRefresh(generation: Int) async {
        let now = nowProvider()
        let access = premiumAccessProvider()
        if access != hasPremiumAccess {
            hasPremiumAccess = access
        }

        guard Self.shouldActivateOSServices(
            hasPremiumAccess: access,
            startMode: startMode
        ) else {
            await deactivateLiveServices(removeReminders: true)
            guard generation == refreshGeneration else { return }
            currentOccurrences = []
            calendars = []
            isAutomationActive = false
            applyPolicyConfiguration(now: now)
            return
        }

        let provider = eventProviderInstance()
        let authorization = await provider.authorizationStatus()
        guard generation == refreshGeneration else { return }
        calendarAuthorization = authorization
        guard authorization == .fullAccess else {
            invalidatePendingRecordingStart()
            calendarAutoStopTrackingActive = false
            collectorShouldBeRunning = false
            cameraCollectorShouldBeRunning = false
            await stopCollector()
            await stopCameraCollector()
            currentOccurrences = []
            calendars = []
            isAutomationActive = false
            applyPolicyConfiguration(now: now)
            return
        }

        do {
            let loadedCalendars = try await provider.calendars()
            guard generation == refreshGeneration else { return }
            calendars = loadedCalendars
            initializeCalendarSelectionIfNeeded(calendars: loadedCalendars)

            let interval = DateInterval(
                start: now.addingTimeInterval(-24 * 60 * 60),
                end: now.addingTimeInterval(7 * 24 * 60 * 60 + 5 * 60)
            )
            let loadedOccurrences = try await provider.occurrences(
                in: interval,
                calendarIDs: selectedCalendarIDs
            )
            guard generation == refreshGeneration else { return }
            currentOccurrences = loadedOccurrences
            isAutomationActive = true
            startEventChangeObservationIfNeeded(provider: provider)

            let notificationService = notificationServiceInstance()
            ensureNotificationRouterInstalled()
            await notificationService.refreshAuthorizationStatus()
            guard generation == refreshGeneration else { return }
            if notificationService.authorization == .notDetermined {
                notificationAuthorization = await notificationService
                    .configureAndRequestAuthorization()
            } else {
                notificationAuthorization = notificationService.authorization
            }
            guard generation == refreshGeneration else { return }
            disableAutoStopIfNotificationsUnavailable()
            applyPolicyConfiguration(now: now)
            scheduleRollingHorizonRefresh()
        } catch {
            guard generation == refreshGeneration else { return }
            currentOccurrences = []
            isAutomationActive = false
            applyPolicyConfiguration(now: now)
        }
    }

    private func initializeCalendarSelectionIfNeeded(
        provider: any CalendarMeetingEventProviding
    ) async {
        guard !defaults.bool(
            forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized
        ), let loadedCalendars = try? await provider.calendars() else {
            return
        }
        initializeCalendarSelectionIfNeeded(calendars: loadedCalendars)
    }

    private func initializeCalendarSelectionIfNeeded(
        calendars: [CalendarMeetingCalendar]
    ) {
        guard !defaults.bool(
            forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized
        ) else {
            return
        }
        selectedCalendarIDs = Set(calendars.map(\.id))
        defaults.set(
            selectedCalendarIDs.sorted(),
            forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs
        )
        defaults.set(
            true,
            forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized
        )
    }

    private func applyPolicyConfiguration(now: Date) {
        let effectiveAutoStopEnabled = autoStopEnabled && canEnableAutoStop
        let configuration = CalendarMeetingAutomationConfiguration(
            hasPremiumAccess: hasPremiumAccess,
            startMode: startMode,
            autoStopEnabled: effectiveAutoStopEnabled,
            calendarAuthorization: calendarAuthorization,
            selectedCalendarIDs: selectedCalendarIDs,
            enabledProviders: enabledProviders,
            suppressedOccurrenceDigests: suppressedDigests
        )
        if activeCalendarRecording != nil,
           (!configuration.isOperational || !configuration.autoStopEnabled) {
            calendarAutoStopTrackingActive = false
        }
        applyPolicy(.configure(configuration, occurrences: currentOccurrences, now: now))
    }

    private func applyPolicy(_ event: CalendarMeetingAutomationEvent) {
        let effects = policy.reduce(event)
        for effect in effects {
            handle(effect)
        }
        scheduleNextPolicyTick()
    }

    private func handle(_ effect: CalendarMeetingAutomationEffect) {
        switch effect {
        case .replaceScheduledReminders(let occurrences):
            guard notificationService != nil || isAutomationActive else { return }
            let service = notificationServiceInstance()
            let now = nowProvider()
            let scheduledStartMode = startMode
            enqueueNotificationOperation {
                await service.replaceScheduledReminders(
                    occurrences,
                    startMode: scheduledStartMode,
                    now: now
                )
            }

        case .startActivityCollector:
            collectorShouldBeRunning = true
            startCollector()

        case .stopActivityCollector:
            collectorShouldBeRunning = false
            if activeCalendarRecording != nil {
                calendarAutoStopTrackingActive = false
            }
            Task { @MainActor [weak self] in await self?.stopCollector() }

        case .startCameraActivityCollector:
            cameraCollectorShouldBeRunning = true
            startCameraCollector()

        case .stopCameraActivityCollector:
            cameraCollectorShouldBeRunning = false
            Task { @MainActor [weak self] in await self?.stopCameraCollector() }

        case .publishDetectedMeeting(let occurrence):
            let service = notificationServiceInstance()
            let now = nowProvider()
            enqueueNotificationOperation {
                await service.publishDetectedMeeting(occurrence, now: now)
            }

        case .showStartCountdown(let occurrence, let deadline):
            countdownModel.presentStart(
                title: occurrence.title,
                startedAt: nowProvider(),
                deadline: deadline
            ) { [weak self] in
                self?.applyPolicy(.userAction(
                    .cancelStartCountdown(occurrence.occurrenceDigest),
                    now: self?.nowProvider() ?? Date()
                ))
            }

        case .dismissStartCountdown:
            countdownModel.dismissStart()

        case .dismissStopCountdown:
            dismissAutoStopWarning()

        case .startRecording(let occurrence, let identity):
            startRecording(occurrence: occurrence, identity: identity)

        case .persistSuppression(let digest):
            persistSuppression(digest)
            requestRefresh()

        case .showStopCountdown(let handle, let deadline):
            presentAutoStopWarning(handle: handle, deadline: deadline)

        case .stopRecording(let handle):
            do {
                try recorderViewModel.stopCalendarMeetingRecording(handle: handle)
            } catch {
                calendarAutoStopTrackingActive = false
                applyPolicy(.recordingStopped(handle, now: nowProvider()))
            }
        }
    }

    private func presentAutoStopWarning(
        handle: CalendarMeetingRecordingHandle,
        deadline: Date
    ) {
        guard let activeCalendarRecording,
              activeCalendarRecording.handle == handle else {
            return
        }
        guard canEnableAutoStop else {
            disableAutoStop()
            applyPolicyConfiguration(now: nowProvider())
            return
        }

        let digest = activeCalendarRecording.occurrenceDigest
        activeAutoStopWarningDigest = digest
        activeAutoStopWarningHandle = handle
        let startedAt = nowProvider()
        countdownModel.presentAutoStop(
            startedAt: startedAt,
            deadline: deadline
        ) { [weak self] in
            self?.continueRecordingAfterAutoStopWarning(
                handle: handle,
                occurrenceDigest: digest
            )
        }
        let service = notificationServiceInstance()
        ensureNotificationRouterInstalled()
        let now = startedAt
        enqueueNotificationOperation { [weak self] in
            let published = await service.publishAutoStopWarning(
                occurrenceDigest: digest,
                now: now
            )
            guard !Task.isCancelled else { return }
            guard let self else {
                if published {
                    service.removeAutoStopWarning(occurrenceDigest: digest)
                }
                return
            }
            self.notificationAuthorization = service.authorization
            guard self.activeAutoStopWarningDigest == digest,
                  self.activeAutoStopWarningHandle == handle else {
                if published {
                    service.removeAutoStopWarning(occurrenceDigest: digest)
                }
                return
            }
            guard published else {
                self.activeAutoStopWarningDigest = nil
                self.activeAutoStopWarningHandle = nil
                self.countdownModel.dismissAutoStop()
                self.disableAutoStop()
                self.applyPolicyConfiguration(now: self.nowProvider())
                return
            }
        }
    }

    private func dismissAutoStopWarning() {
        countdownModel.dismissAutoStop()
        guard let digest = activeAutoStopWarningDigest else {
            activeAutoStopWarningHandle = nil
            return
        }
        activeAutoStopWarningDigest = nil
        activeAutoStopWarningHandle = nil
        guard let notificationService else { return }
        enqueueNotificationOperation {
            notificationService.removeAutoStopWarning(occurrenceDigest: digest)
        }
    }

    private func continueRecordingAfterAutoStopWarning(
        handle: CalendarMeetingRecordingHandle,
        occurrenceDigest: String
    ) {
        guard let activeCalendarRecording,
              activeCalendarRecording.handle == handle,
              activeCalendarRecording.occurrenceDigest == occurrenceDigest,
              activeAutoStopWarningHandle == handle,
              activeAutoStopWarningDigest == occurrenceDigest else {
            return
        }
        calendarAutoStopTrackingActive = false
        applyPolicy(.userAction(
            .continueRecording(handle),
            now: nowProvider()
        ))
    }

    private func disableAutoStopIfNotificationsUnavailable() {
        guard !canEnableAutoStop else { return }
        disableAutoStop()
    }

    private func disableAutoStop() {
        guard autoStopEnabled else { return }
        autoStopEnabled = false
        calendarAutoStopTrackingActive = false
        defaults.set(false, forKey: UserDefaultsKeys.calendarMeetingAutoStopEnabled)
    }

    private func startRecording(
        occurrence: CalendarMeetingOccurrence,
        identity: CalendarMeetingCanonicalLink
    ) {
        guard recordingStartTask == nil else { return }
        recordingStartGeneration += 1
        let generation = recordingStartGeneration
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingStartTask = nil }

            guard self.hasPremiumAccess,
                  self.startMode != .off,
                  self.calendarAuthorization == .fullAccess,
                  self.currentOccurrences.contains(where: {
                      $0.occurrenceDigest == occurrence.occurrenceDigest
                          && $0.isInsideJoinWindow(at: self.nowProvider())
                  }) else {
                self.applyPolicy(.recordingStartFailed(
                    occurrenceDigest: occurrence.occurrenceDigest,
                    failure: .captureFailed
                ))
                return
            }
            let readiness = self.currentRecorderReadiness()
            guard readiness == .idle else {
                self.applyPolicy(.recordingStartDeferred(
                    occurrenceDigest: occurrence.occurrenceDigest,
                    identity: identity,
                    readiness: readiness,
                    now: self.nowProvider()
                ))
                return
            }

            let preferredBaseName = CalendarMeetingRecordingFilename.preferredBaseName(
                title: occurrence.title,
                date: self.nowProvider()
            )
            do {
                let handle = try await self.recorderViewModel.startCalendarMeetingRecording(
                    preferredBaseName: preferredBaseName
                )
                guard generation == self.recordingStartGeneration,
                      self.hasPremiumAccess,
                      self.startMode != .off,
                      self.calendarAuthorization == .fullAccess,
                      self.currentOccurrences.contains(where: {
                          $0.occurrenceDigest == occurrence.occurrenceDigest
                              && $0.isInsideJoinWindow(at: self.nowProvider())
                      }) else {
                    try? self.recorderViewModel.stopCalendarMeetingRecording(handle: handle)
                    self.applyPolicy(.recordingStartFailed(
                        occurrenceDigest: occurrence.occurrenceDigest,
                        failure: .captureFailed
                    ))
                    return
                }
                self.activeCalendarRecording = ActiveCalendarRecordingContext(
                    handle: handle,
                    occurrenceDigest: occurrence.occurrenceDigest,
                    identity: identity
                )
                let autoStopArmed = self.autoStopEnabled
                    && self.canEnableAutoStop
                    && self.hasPremiumAccess
                    && self.startMode != .off
                    && self.calendarAuthorization == .fullAccess
                self.calendarAutoStopTrackingActive = autoStopArmed
                self.applyPolicy(.recordingStarted(
                    handle: handle,
                    occurrenceDigest: occurrence.occurrenceDigest,
                    identity: identity,
                    autoStopArmed: autoStopArmed,
                    now: self.nowProvider()
                ))
            } catch {
                let readiness = self.currentRecorderReadiness()
                switch readiness {
                case .recorderBusy, .dictationBusy, .finalizing:
                    self.applyPolicy(.recordingStartDeferred(
                        occurrenceDigest: occurrence.occurrenceDigest,
                        identity: identity,
                        readiness: readiness,
                        now: self.nowProvider()
                    ))
                case .idle, .noAudioSource, .microphoneDenied:
                    self.applyPolicy(.recordingStartFailed(
                        occurrenceDigest: occurrence.occurrenceDigest,
                        failure: self.mapRecordingStartFailure(error)
                    ))
                }
            }
        }
    }

    private func mapRecordingStartFailure(_ error: Error) -> CalendarMeetingRecordingStartFailure {
        if let recorderError = error as? AudioRecorderService.RecorderError {
            switch recorderError {
            case .noSourceEnabled:
                return .noAudioSource
            case .microphonePermissionDenied:
                return .microphoneDenied
            default:
                return .captureFailed
            }
        }
        if let apiError = error as? AudioRecorderViewModel.RecorderAPIError,
           apiError == .noSourceEnabled {
            return .noAudioSource
        }
        return .captureFailed
    }

    private func recorderOrDictationStateDidChange() {
        if recordingStartTask != nil,
           (dictationViewModel.state != .idle || recorderViewModel.state == .finalizing) {
            invalidatePendingRecordingStart()
        }
        let readiness = currentRecorderReadiness()
        applyPolicy(.recorderReadiness(readiness, now: nowProvider()))

        if recorderViewModel.state != .recording,
           let activeCalendarRecording {
            self.activeCalendarRecording = nil
            calendarAutoStopTrackingActive = false
            applyPolicy(.recordingStopped(
                activeCalendarRecording.handle,
                now: nowProvider()
            ))
        }
    }

    private func currentRecorderReadiness() -> CalendarMeetingRecorderReadiness {
        guard dictationViewModel.state == .idle else { return .dictationBusy }
        guard recorderViewModel.retranscribingRecordingURL == nil else { return .finalizing }
        switch recorderViewModel.state {
        case .recording: return .recorderBusy
        case .finalizing: return .finalizing
        case .idle: break
        }
        guard recorderViewModel.micEnabled || recorderViewModel.systemAudioEnabled else {
            return .noAudioSource
        }
        if recorderViewModel.micEnabled,
           AVAudioApplication.shared.recordPermission != .granted {
            return .microphoneDenied
        }
        return .idle
    }

    private func startCollector() {
        guard collectorTask == nil else { return }
        activityGeneration += 1
        let collector = audioCollectorInstance()
        let sessionID = UUID()
        collectorSessionID = sessionID
        collectorTask = Task { @MainActor [weak self] in
            let stream = await collector.startCollecting()
            for await snapshot in stream {
                guard !Task.isCancelled, let self else { break }
                await self.processActivitySnapshot(snapshot)
            }
            guard let self, self.collectorSessionID == sessionID else { return }
            self.collectorTask = nil
            self.collectorSessionID = nil
            self.collectorShouldBeRunning = false
            self.scheduleNextPolicyTick()
        }
    }

    private func stopCollector() async {
        activityGeneration += 1
        let generation = activityGeneration
        collectorTask?.cancel()
        collectorTask = nil
        collectorSessionID = nil
        let collectorToStop = audioCollector
        audioCollector = nil
        browserResolver = nil
        browserMeetingIdentityByBundleIdentifier.removeAll()
        if let collectorToStop {
            await collectorToStop.stopCollecting()
        }
        guard generation == activityGeneration else { return }
        applyPolicy(.activity([], now: nowProvider()))
        if collectorShouldBeRunning {
            startCollector()
        }
    }

    private func startCameraCollector() {
        guard cameraCollectorTask == nil else { return }
        cameraActivityGeneration += 1
        let collector = cameraCollectorInstance()
        let sessionID = UUID()
        cameraCollectorSessionID = sessionID
        cameraCollectorTask = Task { @MainActor [weak self] in
            let stream = await collector.startCollecting()
            for await snapshot in stream {
                guard !Task.isCancelled, let self else { break }
                self.processCameraActivitySnapshot(snapshot)
            }
            guard let self, self.cameraCollectorSessionID == sessionID else { return }
            self.cameraCollectorTask = nil
            self.cameraCollectorSessionID = nil
            self.cameraCollectorShouldBeRunning = false
            self.scheduleNextPolicyTick()
        }
    }

    private func stopCameraCollector() async {
        cameraActivityGeneration += 1
        let generation = cameraActivityGeneration
        cameraCollectorTask?.cancel()
        cameraCollectorTask = nil
        cameraCollectorSessionID = nil
        let collectorToStop = cameraCollector
        cameraCollector = nil
        if let collectorToStop {
            await collectorToStop.stopCollecting()
        }
        guard generation == cameraActivityGeneration else { return }
        applyPolicy(.cameraActivityUnavailable(now: nowProvider()))
        if cameraCollectorShouldBeRunning {
            startCameraCollector()
        }
    }

    private func processCameraActivitySnapshot(_ snapshot: MeetingCameraActivitySnapshot) {
        cameraActivityGeneration += 1
        guard snapshot.availability == .available else {
            applyPolicy(.cameraActivityUnavailable(now: snapshot.capturedAt))
            return
        }
        applyPolicy(.cameraActivity(
            isRunning: snapshot.isAnyCameraRunning,
            now: snapshot.capturedAt
        ))
    }

    private func processActivitySnapshot(_ snapshot: MeetingActivitySnapshot) async {
        activityGeneration += 1
        let generation = activityGeneration
        guard snapshot.availability == .available else {
            browserMeetingIdentityByBundleIdentifier.removeAll()
            applyPolicy(.activityUnavailable(now: snapshot.capturedAt))
            return
        }

        var signals: [CalendarMeetingJoinSignal] = []
        var activeBrowserResolutionFailed = false
        let activeProcesses = snapshot.processes.filter {
            $0.isRunningInput || $0.isRunningOutput
        }
        for process in activeProcesses {
            if let provider = nativeProvider(for: process.bundleIdentifier) {
                appendNativeSignals(process: process, provider: provider, to: &signals)
            }
        }

        let browserProcesses = Self.aggregatedBrowserProcesses(activeProcesses)
        let activeBrowserBundleIdentifiers = Set(browserProcesses.map(\.bundleIdentifier))
        browserMeetingIdentityByBundleIdentifier =
            browserMeetingIdentityByBundleIdentifier.filter {
                activeBrowserBundleIdentifiers.contains($0.key)
            }
        for process in browserProcesses {
            guard Self.shouldResolveBrowserURL(for: process) else { continue }
            let resolver = browserResolverInstance()
            let resolvedURL = await resolver.activeURL(for: process.bundleIdentifier)
            guard generation == activityGeneration else { return }
            switch Self.browserURLResolution(for: resolvedURL) {
            case .unavailable:
                browserMeetingIdentityByBundleIdentifier.removeValue(
                    forKey: process.bundleIdentifier
                )
                if activeCalendarRecording != nil {
                    activeBrowserResolutionFailed = true
                }
                continue

            case .nonMeeting:
                browserMeetingIdentityByBundleIdentifier.removeValue(
                    forKey: process.bundleIdentifier
                )
                continue

            case .meeting(let link):
                browserMeetingIdentityByBundleIdentifier[process.bundleIdentifier] = link
                appendBrowserSignals(process: process, link: link, to: &signals)
            }
        }
        guard generation == activityGeneration else { return }
        let activeIdentitySignalPresent = activeCalendarRecording.map { active in
            signals.contains {
                $0.occurrenceDigest == active.occurrenceDigest
                    && $0.meetingIdentity == active.identity
                    && $0.countsForAutoStop
            }
        } ?? false
        if activeBrowserResolutionFailed && !activeIdentitySignalPresent {
            applyPolicy(.activityUnavailable(now: snapshot.capturedAt))
            return
        }
        applyPolicy(.activity(signals, now: snapshot.capturedAt))
    }

    private func appendNativeSignals(
        process: MeetingAudioProcess,
        provider: MeetingProvider,
        to signals: inout [CalendarMeetingJoinSignal]
    ) {
        for occurrence in currentOccurrences {
            for link in occurrence.meetingLinks where link.provider == provider {
                appendUniqueSignal(
                    CalendarMeetingJoinSignal(
                        occurrenceDigest: occurrence.occurrenceDigest,
                        meetingIdentity: link,
                        quality: .nativeProvider,
                        isRunningInput: process.isRunningInput,
                        isRunningOutput: process.isRunningOutput
                    ),
                    to: &signals
                )
            }
        }
        if let activeCalendarRecording,
           activeCalendarRecording.identity.provider == provider {
            appendUniqueSignal(
                CalendarMeetingJoinSignal(
                    occurrenceDigest: activeCalendarRecording.occurrenceDigest,
                    meetingIdentity: activeCalendarRecording.identity,
                    quality: .nativeProvider,
                    isRunningInput: process.isRunningInput,
                    isRunningOutput: process.isRunningOutput
                ),
                to: &signals
            )
        }
    }

    private func appendBrowserSignals(
        process: MeetingAudioProcess,
        link: CalendarMeetingCanonicalLink,
        to signals: inout [CalendarMeetingJoinSignal]
    ) {
        for occurrence in currentOccurrences where occurrence.meetingLinks.contains(link) {
            appendUniqueSignal(
                CalendarMeetingJoinSignal(
                    occurrenceDigest: occurrence.occurrenceDigest,
                    meetingIdentity: link,
                    quality: .exactBrowserIdentity,
                    isRunningInput: process.isRunningInput,
                    isRunningOutput: process.isRunningOutput
                ),
                to: &signals
            )
        }
        if let activeCalendarRecording,
           activeCalendarRecording.identity == link {
            appendUniqueSignal(
                CalendarMeetingJoinSignal(
                    occurrenceDigest: activeCalendarRecording.occurrenceDigest,
                    meetingIdentity: link,
                    quality: .exactBrowserIdentity,
                    isRunningInput: process.isRunningInput,
                    isRunningOutput: process.isRunningOutput
                ),
                to: &signals
            )
        }
    }

    private func appendUniqueSignal(
        _ signal: CalendarMeetingJoinSignal,
        to signals: inout [CalendarMeetingJoinSignal]
    ) {
        if !signals.contains(signal) {
            signals.append(signal)
        }
    }

    private func nativeProvider(for bundleIdentifier: String) -> MeetingProvider? {
        NativeMeetingAudioProcessRegistry.provider(for: bundleIdentifier)
    }

    private func scheduleNextPolicyTick() {
        policyTimerTask?.cancel()
        policyTimerTask = nil
        guard hasPremiumAccess,
              startMode != .off,
              calendarAuthorization == .fullAccess else {
            return
        }

        let now = nowProvider()
        let delay: TimeInterval?
        if activeCalendarRecording != nil {
            guard calendarAutoStopTrackingActive else { return }
            delay = 1
        } else if collectorTask != nil || cameraCollectorTask != nil {
            delay = 1
        } else {
            delay = currentOccurrences
                .map { $0.startDate.addingTimeInterval(-10 * 60) }
                .filter { $0 > now }
                .map { $0.timeIntervalSince(now) }
                .min()
        }
        guard let delay else { return }
        let nanoseconds = UInt64(max(0.1, delay) * 1_000_000_000)
        policyTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.applyPolicy(.timeAdvanced(self.nowProvider()))
        }
    }

    private func persistSuppression(_ digest: String) {
        let existing = defaults.stringArray(
            forKey: UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests
        ) ?? []
        let digests = CalendarMeetingSuppressionList.appending(digest, to: existing)
        defaults.set(
            digests,
            forKey: UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests
        )
    }

    private var suppressedDigests: Set<String> {
        Set(defaults.stringArray(
            forKey: UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests
        ) ?? [])
    }

    private func ensureNotificationRouterInstalled() {
        guard !notificationRouterInstalled else { return }
        let service = notificationServiceInstance()
        service.installRouter { [weak self] response in
            self?.handleNotificationResponse(response)
        }
        notificationRouterInstalled = true
    }

    private func handleNotificationResponse(_ response: CalendarMeetingNotificationResponse) {
        switch response {
        case .openPremiumSettings:
            SettingsNavigationCoordinator.shared.navigate(to: .premium)
            ManagedAppWindowOpener.shared.open(id: "settings")
        case .continueRecording(let digest):
            guard let activeCalendarRecording,
                  activeCalendarRecording.occurrenceDigest == digest,
                  activeAutoStopWarningDigest == digest,
                  activeAutoStopWarningHandle == activeCalendarRecording.handle else {
                return
            }
            continueRecordingAfterAutoStopWarning(
                handle: activeCalendarRecording.handle,
                occurrenceDigest: digest
            )
        case .armStart(let digest), .suppress(let digest):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAndWaitForCurrentGeneration()
                guard self.currentOccurrences.contains(where: {
                    $0.occurrenceDigest == digest
                        && $0.isInsideJoinWindow(at: self.nowProvider())
                }) else {
                    return
                }
                guard let action = Self.automationUserAction(for: response) else {
                    return
                }
                self.applyPolicy(.userAction(action, now: self.nowProvider()))
            }
        }
    }

    private func startEventChangeObservationIfNeeded(
        provider: any CalendarMeetingEventProviding
    ) {
        guard eventChangesTask == nil else { return }
        let sessionID = UUID()
        eventChangesSessionID = sessionID
        eventChangesTask = Task { @MainActor [weak self] in
            let stream = await provider.changes()
            for await _ in stream {
                guard !Task.isCancelled,
                      let self,
                      self.eventChangesSessionID == sessionID else { break }
                self.requestRefresh()
            }
            guard let self, self.eventChangesSessionID == sessionID else { return }
            self.eventChangesTask = nil
            self.eventChangesSessionID = nil
        }
    }

    private func refreshAndWaitForCurrentGeneration() async {
        requestRefresh()
        while true {
            let generation = refreshGeneration
            let task = refreshTask
            await task?.value
            guard generation != refreshGeneration else { return }
        }
    }

    private func observeEnvironmentChanges() {
        let names: [Notification.Name] = [
            .NSSystemTimeZoneDidChange,
            .NSSystemClockDidChange
        ]
        environmentObserverTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.requestRefresh() }
            }
        }
    }

    private func deactivateLiveServices(removeReminders: Bool) async {
        horizonRefreshTask?.cancel()
        horizonRefreshTask = nil
        eventChangesTask?.cancel()
        eventChangesTask = nil
        eventChangesSessionID = nil
        eventProvider = nil
        browserResolver = nil
        collectorShouldBeRunning = false
        cameraCollectorShouldBeRunning = false
        await stopCollector()
        await stopCameraCollector()
        countdownModel.dismissAll()
        let pendingNotificationTask = notificationTask
        pendingNotificationTask?.cancel()
        await pendingNotificationTask?.value
        notificationTask = nil
        if let activeAutoStopWarningDigest, let notificationService {
            notificationService.removeAutoStopWarning(
                occurrenceDigest: activeAutoStopWarningDigest
            )
            self.activeAutoStopWarningDigest = nil
        }
        activeAutoStopWarningHandle = nil
        if removeReminders, let notificationService {
            await notificationService.removeScheduledMeetingRequests()
        }
    }

    private func eventProviderInstance() -> any CalendarMeetingEventProviding {
        if let eventProvider { return eventProvider }
        let provider = eventProviderFactory()
        eventProvider = provider
        return provider
    }

    private func audioCollectorInstance() -> any MeetingAudioActivityCollecting {
        if let audioCollector { return audioCollector }
        let collector = audioCollectorFactory()
        audioCollector = collector
        return collector
    }

    private func cameraCollectorInstance() -> any MeetingCameraActivityCollecting {
        if let cameraCollector { return cameraCollector }
        let collector = cameraCollectorFactory()
        cameraCollector = collector
        return collector
    }

    private func browserResolverInstance() -> any BrowserURLResolving {
        if let browserResolver { return browserResolver }
        let resolver = browserResolverFactory()
        browserResolver = resolver
        return resolver
    }

    private func notificationServiceInstance() -> any CalendarMeetingNotifying {
        if let notificationService { return notificationService }
        let service = notificationServiceFactory()
        notificationService = service
        return service
    }

    private func openSystemSettings(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func enqueueNotificationOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previousTask = notificationTask
        previousTask?.cancel()
        notificationTask = Task { @MainActor in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func scheduleRollingHorizonRefresh() {
        horizonRefreshTask?.cancel()
        horizonRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(24 * 60 * 60))
            guard !Task.isCancelled, let self else { return }
            self.requestRefresh()
        }
    }

    private func invalidatePendingRecordingStart() {
        recordingStartGeneration += 1
    }
}
