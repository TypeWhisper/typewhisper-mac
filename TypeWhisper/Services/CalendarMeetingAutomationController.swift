import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class CalendarMeetingAutomationController: ObservableObject {
    nonisolated static func shouldActivateOSServices(
        hasPremiumAccess: Bool,
        startMode: CalendarMeetingStartMode
    ) -> Bool {
        hasPremiumAccess && startMode != .off
    }

    nonisolated static func shouldResolveBrowserURL(for process: MeetingAudioProcess) -> Bool {
        process.isRunningInput
            && SupportedMeetingBrowser.supportsAutomaticURLResolution(process.bundleIdentifier)
    }

    typealias EventProviderFactory = @MainActor () -> any CalendarMeetingEventProviding
    typealias AudioCollectorFactory = @MainActor () -> any MeetingAudioActivityCollecting
    typealias BrowserResolverFactory = @MainActor () -> any BrowserURLResolving
    typealias NotificationServiceFactory = @MainActor () -> any CalendarMeetingNotifying
    typealias CountdownPresenterFactory = @MainActor () -> any MeetingAutomationCountdownPresenting

    @Published private(set) var hasPremiumAccess: Bool
    @Published private(set) var startMode: CalendarMeetingStartMode
    @Published private(set) var autoStopEnabled: Bool
    @Published private(set) var selectedCalendarIDs: Set<String>
    @Published private(set) var enabledProviders: Set<MeetingProvider>
    @Published private(set) var calendars: [CalendarMeetingCalendar] = []
    @Published private(set) var calendarAuthorization: CalendarMeetingCalendarAuthorization = .notDetermined
    @Published private(set) var notificationAuthorization: CalendarMeetingNotificationAuthorization = .notDetermined
    @Published private(set) var isAutomationActive = false
    @Published var permissionExplanationPresented = false

    private struct ActiveCalendarRecordingContext {
        let handle: CalendarMeetingRecordingHandle
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
    }

    private let licenseService: LicenseService
    private let premiumAccountService: PremiumAccountService
    private let recorderViewModel: AudioRecorderViewModel
    private let dictationViewModel: DictationViewModel
    private let defaults: UserDefaults
    private let eventProviderFactory: EventProviderFactory
    private let audioCollectorFactory: AudioCollectorFactory
    private let browserResolverFactory: BrowserResolverFactory
    private let notificationServiceFactory: NotificationServiceFactory
    private let countdownPresenterFactory: CountdownPresenterFactory
    private let premiumAccessProvider: @MainActor () -> Bool
    private let nowProvider: @MainActor () -> Date

    private var policy = CalendarMeetingAutomationPolicy()
    private var currentOccurrences: [CalendarMeetingOccurrence] = []
    private var eventProvider: (any CalendarMeetingEventProviding)?
    private var audioCollector: (any MeetingAudioActivityCollecting)?
    private var browserResolver: (any BrowserURLResolving)?
    private var notificationService: (any CalendarMeetingNotifying)?
    private var countdownPresenter: (any MeetingAutomationCountdownPresenting)?
    private var activeCalendarRecording: ActiveCalendarRecordingContext?
    private var browserMeetingIdentityByProcessID: [pid_t: CalendarMeetingCanonicalLink] = [:]
    private var calendarAutoStopTrackingActive = false
    private var pendingStartMode: CalendarMeetingStartMode?
    private var notificationRouterInstalled = false
    private var initialized = false
    private var refreshGeneration = 0
    private var activityGeneration = 0
    private var recordingStartGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var horizonRefreshTask: Task<Void, Never>?
    private var eventChangesTask: Task<Void, Never>?
    private var eventChangesSessionID: UUID?
    private var collectorTask: Task<Void, Never>?
    private var collectorSessionID: UUID?
    private var collectorShouldBeRunning = false
    private var policyTimerTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var environmentObserverTokens: [NSObjectProtocol] = []

    init(
        licenseService: LicenseService,
        premiumAccountService: PremiumAccountService,
        recorderViewModel: AudioRecorderViewModel,
        dictationViewModel: DictationViewModel,
        defaults: UserDefaults = .standard,
        eventProviderFactory: @escaping EventProviderFactory = { EventKitCalendarMeetingProvider() },
        audioCollectorFactory: @escaping AudioCollectorFactory = { MeetingAudioActivityCollector() },
        browserResolverFactory: @escaping BrowserResolverFactory = { BrowserURLResolver() },
        notificationServiceFactory: @escaping NotificationServiceFactory = {
            CalendarMeetingNotificationService()
        },
        countdownPresenterFactory: @escaping CountdownPresenterFactory = {
            MeetingAutomationCountdownPanelController()
        },
        premiumAccessProvider: (@MainActor () -> Bool)? = nil,
        nowProvider: @escaping @MainActor () -> Date = Date.init
    ) {
        self.licenseService = licenseService
        self.premiumAccountService = premiumAccountService
        self.recorderViewModel = recorderViewModel
        self.dictationViewModel = dictationViewModel
        self.defaults = defaults
        self.eventProviderFactory = eventProviderFactory
        self.audioCollectorFactory = audioCollectorFactory
        self.browserResolverFactory = browserResolverFactory
        self.notificationServiceFactory = notificationServiceFactory
        self.countdownPresenterFactory = countdownPresenterFactory
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
        }
        if mode == .off {
            pendingStartMode = nil
            permissionExplanationPresented = false
            persistStartMode(.off)
            requestRefresh()
            return
        }
        if startMode == .off {
            pendingStartMode = mode
            permissionExplanationPresented = true
        } else {
            persistStartMode(mode)
            requestRefresh()
        }
    }

    func confirmPermissionExplanation() {
        guard let pendingStartMode else { return }
        self.pendingStartMode = nil
        permissionExplanationPresented = false
        persistStartMode(pendingStartMode)

        guard premiumAccessProvider() else {
            entitlementDidChange()
            return
        }
        Task { @MainActor [weak self] in
            await self?.requestCalendarAndNotificationAccess()
        }
    }

    func cancelPermissionExplanation() {
        pendingStartMode = nil
        permissionExplanationPresented = false
    }

    func setAutoStopEnabled(_ enabled: Bool) {
        guard autoStopEnabled != enabled else { return }
        autoStopEnabled = enabled
        if !enabled {
            calendarAutoStopTrackingActive = false
        }
        defaults.set(enabled, forKey: UserDefaultsKeys.calendarMeetingAutoStopEnabled)
        applyPolicyConfiguration(now: nowProvider())
    }

    func setCalendar(_ calendarID: String, enabled: Bool) {
        invalidatePendingRecordingStart()
        if activeCalendarRecording != nil {
            calendarAutoStopTrackingActive = false
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
        policyTimerTask?.cancel()
        policyTimerTask = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        invalidatePendingRecordingStart()
        countdownPresenter?.dismiss()
        if let audioCollector {
            Task { await audioCollector.stopCollecting() }
        }
        self.audioCollector = nil
        eventProvider = nil
        browserResolver = nil
        browserMeetingIdentityByProcessID.removeAll()
        calendarAutoStopTrackingActive = false
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
        }
        hasPremiumAccess = access
        requestRefresh()
    }

    private func persistStartMode(_ mode: CalendarMeetingStartMode) {
        startMode = mode
        defaults.set(mode.rawValue, forKey: UserDefaultsKeys.calendarMeetingStartMode)
    }

    private func requestCalendarAndNotificationAccess() async {
        let provider = eventProviderInstance()
        _ = try? await provider.requestFullAccess()
        calendarAuthorization = await provider.authorizationStatus()
        guard calendarAuthorization == .fullAccess else {
            requestRefresh()
            return
        }

        await initializeCalendarSelectionIfNeeded(provider: provider)
        let notificationService = notificationServiceInstance()
        ensureNotificationRouterInstalled()
        notificationAuthorization = await notificationService.configureAndRequestAuthorization()
        requestRefresh()
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
            await stopCollector()
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
        let configuration = CalendarMeetingAutomationConfiguration(
            hasPremiumAccess: hasPremiumAccess,
            startMode: startMode,
            autoStopEnabled: autoStopEnabled,
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
            enqueueNotificationOperation {
                await service.replaceScheduledReminders(occurrences, now: now)
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

        case .publishDetectedMeeting(let occurrence):
            let service = notificationServiceInstance()
            let now = nowProvider()
            enqueueNotificationOperation {
                await service.publishDetectedMeeting(occurrence, now: now)
            }

        case .showStartCountdown(let occurrence, let deadline):
            let presenter = countdownPresenterInstance()
            presenter.showStart(title: occurrence.title, deadline: deadline) { [weak self] in
                self?.applyPolicy(.userAction(
                    .cancelStartCountdown(occurrence.occurrenceDigest),
                    now: self?.nowProvider() ?? Date()
                ))
            }

        case .dismissStartCountdown, .dismissStopCountdown:
            countdownPresenter?.dismiss()

        case .startRecording(let occurrence, let identity):
            startRecording(occurrence: occurrence, identity: identity)

        case .persistSuppression(let digest):
            persistSuppression(digest)
            requestRefresh()

        case .showStopCountdown(let handle, let deadline):
            let presenter = countdownPresenterInstance()
            presenter.showStop(deadline: deadline) { [weak self] in
                self?.calendarAutoStopTrackingActive = false
                self?.applyPolicy(.userAction(
                    .continueRecording(handle),
                    now: self?.nowProvider() ?? Date()
                ))
            }

        case .stopRecording(let handle):
            do {
                try recorderViewModel.stopCalendarMeetingRecording(handle: handle)
            } catch {
                calendarAutoStopTrackingActive = false
                applyPolicy(.recordingStopped(handle, now: nowProvider()))
            }
        }
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
        browserMeetingIdentityByProcessID.removeAll()
        if let collectorToStop {
            await collectorToStop.stopCollecting()
        }
        guard generation == activityGeneration else { return }
        applyPolicy(.activity([], now: nowProvider()))
        if collectorShouldBeRunning {
            startCollector()
        }
    }

    private func processActivitySnapshot(_ snapshot: MeetingActivitySnapshot) async {
        activityGeneration += 1
        let generation = activityGeneration
        guard snapshot.availability == .available else {
            browserMeetingIdentityByProcessID.removeAll()
            applyPolicy(.activityUnavailable(now: snapshot.capturedAt))
            return
        }

        let presentProcessIDs = Set(snapshot.processes.map(\.processID))
        browserMeetingIdentityByProcessID = browserMeetingIdentityByProcessID.filter {
            presentProcessIDs.contains($0.key)
        }
        for process in snapshot.processes
        where !process.isRunningInput && !process.isRunningOutput {
            browserMeetingIdentityByProcessID.removeValue(forKey: process.processID)
        }
        var signals: [CalendarMeetingJoinSignal] = []
        var activeBrowserResolutionFailed = false
        for process in snapshot.processes where process.isRunningInput || process.isRunningOutput {
            if let provider = nativeProvider(for: process.bundleIdentifier) {
                appendNativeSignals(process: process, provider: provider, to: &signals)
                continue
            }
            guard SupportedMeetingBrowser.supportsAutomaticURLResolution(process.bundleIdentifier) else {
                continue
            }
            if !Self.shouldResolveBrowserURL(for: process) {
                if let link = browserMeetingIdentityByProcessID[process.processID] {
                    appendBrowserSignals(process: process, link: link, to: &signals)
                }
                continue
            }
            let resolver = browserResolverInstance()
            guard let url = await resolver.activeURL(for: process.bundleIdentifier),
                  generation == activityGeneration,
                  let link = MeetingLinkParser().parse(url: url) else {
                if generation == activityGeneration {
                    browserMeetingIdentityByProcessID.removeValue(forKey: process.processID)
                    if activeCalendarRecording != nil {
                        activeBrowserResolutionFailed = true
                    }
                }
                continue
            }
            browserMeetingIdentityByProcessID[process.processID] = link
            appendBrowserSignals(process: process, link: link, to: &signals)
        }
        guard generation == activityGeneration else { return }
        let activeIdentitySignalPresent = activeCalendarRecording.map { active in
            signals.contains {
                $0.occurrenceDigest == active.occurrenceDigest
                    && $0.meetingIdentity == active.identity
                    && ($0.isRunningInput || $0.isRunningOutput)
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
        switch bundleIdentifier {
        case "us.zoom.xos": .zoom
        case "com.microsoft.teams2", "com.microsoft.teams": .teams
        case "com.apple.FaceTime": .faceTime
        default: nil
        }
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
        } else if collectorTask != nil {
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
        case .start(let digest), .suppress(let digest):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAndWaitForCurrentGeneration()
                guard self.currentOccurrences.contains(where: {
                    $0.occurrenceDigest == digest
                        && $0.isInsideJoinWindow(at: self.nowProvider())
                }) else {
                    return
                }
                let action: CalendarMeetingAutomationUserAction
                switch response {
                case .start:
                    action = .startOccurrence(digest)
                case .suppress:
                    action = .suppressOccurrence(digest)
                case .openPremiumSettings:
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
        await stopCollector()
        countdownPresenter?.dismiss()
        let pendingNotificationTask = notificationTask
        pendingNotificationTask?.cancel()
        await pendingNotificationTask?.value
        notificationTask = nil
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

    private func countdownPresenterInstance() -> any MeetingAutomationCountdownPresenting {
        if let countdownPresenter { return countdownPresenter }
        let presenter = countdownPresenterFactory()
        countdownPresenter = presenter
        return presenter
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
