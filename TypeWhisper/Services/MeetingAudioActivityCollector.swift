import CoreAudio
import Foundation
import os

protocol MeetingAudioProcessClient: Sendable {
    func start(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool
    func restart(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool
    func snapshot(at date: Date) -> MeetingActivitySnapshot
    func stop()
}

enum NativeMeetingAudioProcessRegistry {
    // App bundles whose helper processes count as the app itself. New Teams, for
    // example, runs call audio in `com.microsoft.teams2.modulehost`.
    nonisolated static let appBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "kontur.talk"
    ]

    nonisolated static func provider(for bundleIdentifier: String) -> MeetingProvider? {
        switch bundleIdentifier {
        case "us.zoom.xos":
            .zoom
        case "com.microsoft.teams2", "com.microsoft.teams":
            .teams
        case "kontur.talk":
            // Kontur Talk is an Electron app. Its `kontur.talk.helper*` processes
            // count as the app through the namespace rule below.
            .konturTalk
        case "com.apple.FaceTime",
             "com.apple.FaceTime.FTConversationService",
             "com.apple.avconferenced",
             "com.apple.TelephonyUtilities":
            // Recent macOS versions attribute FaceTime audio I/O to these Apple services
            // instead of the FaceTime application process itself. TelephonyUtilities is
            // treated only as a FaceTime signal by the controller when a matching FaceTime
            // calendar occurrence is already inside its join window.
            .faceTime
        default:
            nil
        }
    }

    /// Maps a helper process to the meeting app it belongs to, either by its
    /// bundle identifier namespace or by the app bundle its executable lives in.
    nonisolated static func appBundleIdentifier(
        forHelper bundleIdentifier: String,
        executablePath: @autoclosure () -> String?
    ) -> String? {
        if let app = appBundleIdentifiers
            .filter({ bundleIdentifier.hasPrefix($0 + ".") })
            .max(by: { $0.count < $1.count }) {
            return app
        }
        guard let executablePath = executablePath(),
              let app = outermostAppBundleIdentifier(containing: executablePath),
              appBundleIdentifiers.contains(app) else {
            return nil
        }
        return app
    }

    nonisolated static func outermostAppBundleIdentifier(containing executablePath: String) -> String? {
        outermostAppBundleURL(containing: executablePath).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    nonisolated static func outermostAppBundleURL(containing executablePath: String) -> URL? {
        let components = URL(fileURLWithPath: executablePath).pathComponents
        guard let index = components.dropLast().firstIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return URL(
            fileURLWithPath: NSString.path(withComponents: Array(components[...index])),
            isDirectory: true
        )
    }
}

private final class CoreAudioChangeCallbackBridge: @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)

    func setHandler(_ newHandler: (@Sendable (Bool) -> Void)?) {
        handler.withLock { $0 = newHandler }
    }

    func notify(requiresRebuild: Bool) {
        let callback = handler.withLock { $0 }
        callback?(requiresRebuild)
    }
}

private final class CoreAudioListenerRegistration: @unchecked Sendable {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }
}

/// What a CoreAudio process object stands for. CoreAudio creates one object
/// per client process, so its PID, bundle identifier and executable stay the
/// same for as long as the object is listed.
struct MeetingAudioProcessIdentity: Equatable, Sendable {
    let processID: pid_t
    /// The canonical meeting app or browser, or nil when the process can never
    /// be a meeting source (including TypeWhisper itself).
    let bundleIdentifier: String?
}

/// Remembers process identities between snapshots, so a pass reads only the
/// running state of relevant processes instead of every static property.
struct MeetingAudioProcessIdentityCache: Sendable {
    private var identities: [AudioObjectID: MeetingAudioProcessIdentity] = [:]

    var cachedObjectIDs: Set<AudioObjectID> { Set(identities.keys) }

    /// Returns the identity of every listed object that could be resolved, in
    /// list order. Objects that left the list are forgotten, and an object whose
    /// identity could not be read is tried again on the next pass.
    mutating func identities(
        for objectIDs: [AudioObjectID],
        resolve: (AudioObjectID) -> MeetingAudioProcessIdentity?
    ) -> [(objectID: AudioObjectID, identity: MeetingAudioProcessIdentity)] {
        let listed = Set(objectIDs)
        identities = identities.filter { listed.contains($0.key) }
        return objectIDs.compactMap { objectID in
            if let cached = identities[objectID] {
                return (objectID, cached)
            }
            guard let resolved = resolve(objectID) else { return nil }
            identities[objectID] = resolved
            return (objectID, resolved)
        }
    }
}

private struct CoreAudioProcessClientState {
    var systemRegistrations: [CoreAudioListenerRegistration] = []
    var processRegistrations: [AudioObjectID: [CoreAudioListenerRegistration]] = [:]
    // Reset with the rest of the state on stop, start and HAL restart, because
    // a restarted coreaudiod can hand out the same object IDs again.
    var processIdentities = MeetingAudioProcessIdentityCache()
    var started = false
}

final class CoreAudioMeetingProcessClient: MeetingAudioProcessClient, @unchecked Sendable {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    private let callbackQueue = DispatchQueue(
        label: "com.typewhisper.calendar-meeting-audio",
        qos: .utility
    )
    private let callbackBridge = CoreAudioChangeCallbackBridge()
    private let state = OSAllocatedUnfairLock(initialState: CoreAudioProcessClientState())
    private let ownProcessID: pid_t
    private let ownBundleIdentifier: String

    init(
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.ownProcessID = ownProcessID
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    func start(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool {
        stop()
        callbackBridge.setHandler(changeHandler)

        let processListAddress = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        guard hasProperty(objectID: systemObjectID, address: processListAddress),
              let processListRegistration = addListener(
                  objectID: systemObjectID,
                  address: processListAddress
              ) else {
            callbackBridge.setHandler(nil)
            return false
        }

        var registrations = [processListRegistration]
        let serviceRestartedAddress = propertyAddress(kAudioHardwarePropertyServiceRestarted)
        // This resilience hook is not advertised on every supported macOS version.
        if hasProperty(objectID: systemObjectID, address: serviceRestartedAddress),
           let serviceRestartedRegistration = addListener(
               objectID: systemObjectID,
               address: serviceRestartedAddress
           ) {
            registrations.append(serviceRestartedRegistration)
        }
        let installedRegistrations = registrations
        state.withLock {
            $0.systemRegistrations = installedRegistrations
            $0.started = true
        }
        return true
    }

    func restart(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool {
        start(changeHandler: changeHandler)
    }

    func snapshot(at date: Date) -> MeetingActivitySnapshot {
        guard state.withLock({ $0.started }) else {
            return .unsupported(at: date)
        }
        guard let objectIDs = readProcessObjectIDs() else {
            return .failed(at: date)
        }

        var identityCache = state.withLock { $0.processIdentities }
        let identities = identityCache.identities(for: objectIDs, resolve: readProcessIdentity)
        state.withLock { [identityCache] in $0.processIdentities = identityCache }

        var processes: [MeetingAudioProcess] = []
        var relevantObjectIDs = Set<AudioObjectID>()
        for (objectID, identity) in identities {
            guard let bundleIdentifier = identity.bundleIdentifier,
                  let isRunningInput = readFlag(
                      objectID: objectID,
                      selector: kAudioProcessPropertyIsRunningInput
                  ),
                  let isRunningOutput = readFlag(
                      objectID: objectID,
                      selector: kAudioProcessPropertyIsRunningOutput
                  ) else {
                continue
            }
            relevantObjectIDs.insert(objectID)
            processes.append(MeetingAudioProcess(
                audioObjectID: objectID,
                processID: identity.processID,
                bundleIdentifier: bundleIdentifier,
                isRunningInput: isRunningInput,
                isRunningOutput: isRunningOutput
            ))
        }

        guard reconcileProcessListeners(objectIDs: relevantObjectIDs) else {
            return .failed(at: date)
        }
        return MeetingActivitySnapshot(
            capturedAt: date,
            availability: .available,
            processes: processes.sorted {
                if $0.bundleIdentifier != $1.bundleIdentifier {
                    return $0.bundleIdentifier < $1.bundleIdentifier
                }
                return $0.processID < $1.processID
            }
        )
    }

    func stop() {
        let registrations = state.withLock { current -> [CoreAudioListenerRegistration] in
            let all = current.systemRegistrations + current.processRegistrations.values.flatMap { $0 }
            current = CoreAudioProcessClientState()
            return all
        }
        callbackBridge.setHandler(nil)
        registrations.forEach(removeListener)
    }

    var cachedProcessObjectIDs: Set<AudioObjectID> {
        state.withLock { $0.processIdentities.cachedObjectIDs }
    }

    private func readProcessObjectIDs() -> [AudioObjectID]? {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectHasProperty(systemObjectID, &address) else { return nil }
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }
        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = Array(repeating: AudioObjectID(0), count: count)
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                systemObjectID,
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        let returnedCount = min(values.count, Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        return Array(values.prefix(returnedCount))
    }

    private func readProcessIdentity(objectID: AudioObjectID) -> MeetingAudioProcessIdentity? {
        // Reads go straight to GetPropertyData: it fails for a missing property
        // or a vanished object just like a separate HasProperty check would.
        guard let processID: pid_t = readScalar(
            objectID: objectID,
            address: propertyAddress(kAudioProcessPropertyPID)
        ),
        let bundleIdentifier = readBundleIdentifier(objectID: objectID) else {
            return nil
        }
        guard processID != ownProcessID, bundleIdentifier != ownBundleIdentifier else {
            return MeetingAudioProcessIdentity(processID: processID, bundleIdentifier: nil)
        }
        return MeetingAudioProcessIdentity(
            processID: processID,
            bundleIdentifier: Self.canonicalBundleIdentifier(
                for: bundleIdentifier,
                executablePath: Self.executablePath(processID: processID)
            )
        )
    }

    private func readFlag(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        let value: UInt32? = readScalar(objectID: objectID, address: propertyAddress(selector))
        return value.map { $0 != 0 }
    }

    private func readBundleIdentifier(objectID: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            &value
        ) == noErr,
        let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func readScalar<T>(
        objectID: AudioObjectID,
        address initialAddress: AudioObjectPropertyAddress
    ) -> T? {
        var address = initialAddress
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        var byteCount = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &byteCount,
            pointer
        ) == noErr,
        byteCount == MemoryLayout<T>.size else {
            return nil
        }
        return pointer.load(as: T.self)
    }

    private func reconcileProcessListeners(objectIDs: Set<AudioObjectID>) -> Bool {
        let stale = state.withLock { Set($0.processRegistrations.keys).subtracting(objectIDs) }
        for objectID in stale {
            let registrations = state.withLock { $0.processRegistrations.removeValue(forKey: objectID) ?? [] }
            registrations.forEach(removeListener)
        }

        let known = state.withLock { Set($0.processRegistrations.keys) }
        for objectID in objectIDs.subtracting(known) {
            let addresses = [
                propertyAddress(kAudioProcessPropertyIsRunningInput),
                propertyAddress(kAudioProcessPropertyIsRunningOutput)
            ]
            guard addresses.allSatisfy({ hasProperty(objectID: objectID, address: $0) }) else {
                return false
            }
            let registrations = addresses.compactMap { addListener(objectID: objectID, address: $0) }
            guard registrations.count == addresses.count else {
                registrations.forEach(removeListener)
                return false
            }
            state.withLock { $0.processRegistrations[objectID] = registrations }
        }
        return true
    }

    private func addListener(
        objectID: AudioObjectID,
        address initialAddress: AudioObjectPropertyAddress
    ) -> CoreAudioListenerRegistration? {
        var address = initialAddress
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        let block = makeMeetingAudioPropertyListenerBlock(callbackBridge)
        guard AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            callbackQueue,
            block
        ) == noErr else {
            return nil
        }
        return CoreAudioListenerRegistration(
            objectID: objectID,
            address: initialAddress,
            queue: callbackQueue,
            block: block
        )
    }

    private func removeListener(_ registration: CoreAudioListenerRegistration) {
        var address = registration.address
        guard AudioObjectHasProperty(registration.objectID, &address) else { return }
        AudioObjectRemovePropertyListenerBlock(
            registration.objectID,
            &address,
            registration.queue,
            registration.block
        )
    }

    private func hasProperty(
        objectID: AudioObjectID,
        address initialAddress: AudioObjectPropertyAddress
    ) -> Bool {
        var address = initialAddress
        return AudioObjectHasProperty(objectID, &address)
    }

    nonisolated static func canonicalBundleIdentifier(
        for bundleIdentifier: String,
        executablePath: @autoclosure () -> String?
    ) -> String? {
        if NativeMeetingAudioProcessRegistry.provider(for: bundleIdentifier) != nil {
            return bundleIdentifier
        }
        if let browserBundleIdentifier = BrowserAudioProcessAttribution
            .canonicalBrowserBundleIdentifier(
                for: bundleIdentifier,
                hostAppBundleIdentifier: executablePath().flatMap(
                    NativeMeetingAudioProcessRegistry.outermostAppBundleIdentifier(containing:)
                )
            ) {
            return browserBundleIdentifier
        }
        return NativeMeetingAudioProcessRegistry.appBundleIdentifier(
            forHelper: bundleIdentifier,
            executablePath: executablePath()
        )
    }

    nonisolated private static func executablePath(processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return String(bytes: buffer.prefix(end).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func makeMeetingAudioPropertyListenerBlock(
    _ bridge: CoreAudioChangeCallbackBridge
) -> AudioObjectPropertyListenerBlock {
    { addressCount, addresses in
        let serviceRestarted = (0..<Int(addressCount)).contains {
            addresses[$0].mSelector == kAudioHardwarePropertyServiceRestarted
        }
        bridge.notify(requiresRebuild: serviceRestarted)
    }
}

private func makeMeetingAudioCollectorChangeHandler(
    _ collector: MeetingAudioActivityCollector
) -> @Sendable (Bool) -> Void {
    { [weak collector] requiresRebuild in
        guard let collector else { return }
        Task {
            await collector.audioPropertiesDidChange(requiresRebuild: requiresRebuild)
        }
    }
}

actor MeetingAudioActivityCollector: MeetingAudioActivityCollecting {
    private let client: any MeetingAudioProcessClient
    private let reconciliationInterval: Duration?
    private var continuation: AsyncStream<MeetingActivitySnapshot>.Continuation?
    private var reconciliationTask: Task<Void, Never>?
    private var lastPublishedSnapshot: MeetingActivitySnapshot?
    private var isCollecting = false

    init() {
        client = CoreAudioMeetingProcessClient()
        reconciliationInterval = .seconds(1)
    }

    init(
        client: any MeetingAudioProcessClient,
        reconciliationInterval: Duration? = .seconds(1)
    ) {
        self.client = client
        self.reconciliationInterval = reconciliationInterval
    }

    deinit {
        reconciliationTask?.cancel()
        client.stop()
    }

    func startCollecting() -> AsyncStream<MeetingActivitySnapshot> {
        stopCollecting()
        let pair = AsyncStream<MeetingActivitySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = pair.continuation

        let handler = makeMeetingAudioCollectorChangeHandler(self)
        guard client.start(changeHandler: handler) else {
            pair.continuation.yield(.unsupported())
            pair.continuation.finish()
            continuation = nil
            return pair.stream
        }
        isCollecting = true
        publishCurrentSnapshot(force: true)
        startPeriodicReconciliation()
        return pair.stream
    }

    func stopCollecting() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        guard isCollecting || continuation != nil else { return }
        isCollecting = false
        client.stop()
        continuation?.finish()
        continuation = nil
        lastPublishedSnapshot = nil
    }

    fileprivate func audioPropertiesDidChange(requiresRebuild: Bool) {
        guard isCollecting else { return }
        if requiresRebuild {
            let handler = makeMeetingAudioCollectorChangeHandler(self)
            guard client.restart(changeHandler: handler) else {
                continuation?.yield(.unsupported())
                stopCollecting()
                return
            }
        }
        // A CoreAudio callback represents a real property event even when the
        // resulting values happen to compare equal. Preserve that event-driven
        // behavior; only the periodic reconciliation path suppresses duplicates.
        publishCurrentSnapshot(force: true)
    }

    private func startPeriodicReconciliation() {
        reconciliationTask?.cancel()
        guard let reconciliationInterval else { return }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: reconciliationInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.publishCurrentSnapshot()
            }
        }
    }

    private func publishCurrentSnapshot(force: Bool = false) {
        guard isCollecting else { return }
        let snapshot = client.snapshot(at: Date())
        if !force,
           let lastPublishedSnapshot,
           lastPublishedSnapshot.availability == snapshot.availability,
           lastPublishedSnapshot.processes == snapshot.processes {
            return
        }
        lastPublishedSnapshot = snapshot
        continuation?.yield(snapshot)
    }
}
