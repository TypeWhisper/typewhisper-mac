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
    nonisolated static func provider(for bundleIdentifier: String) -> MeetingProvider? {
        switch bundleIdentifier {
        case "us.zoom.xos":
            .zoom
        case "com.microsoft.teams2", "com.microsoft.teams":
            .teams
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

private struct CoreAudioProcessClientState {
    var systemRegistrations: [CoreAudioListenerRegistration] = []
    var processRegistrations: [AudioObjectID: [CoreAudioListenerRegistration]] = [:]
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

        var processes: [MeetingAudioProcess] = []
        var relevantObjectIDs = Set<AudioObjectID>()
        for objectID in objectIDs {
            guard let rawProcess = readProcess(objectID: objectID) else { continue }
            guard rawProcess.processID != ownProcessID,
                  rawProcess.bundleIdentifier != ownBundleIdentifier else {
                continue
            }
            guard let bundleIdentifier = Self.canonicalBundleIdentifier(
                for: rawProcess.bundleIdentifier
            ) else {
                continue
            }
            relevantObjectIDs.insert(objectID)
            processes.append(MeetingAudioProcess(
                audioObjectID: rawProcess.audioObjectID,
                processID: rawProcess.processID,
                bundleIdentifier: bundleIdentifier,
                isRunningInput: rawProcess.isRunningInput,
                isRunningOutput: rawProcess.isRunningOutput
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

    private func readProcess(objectID: AudioObjectID) -> MeetingAudioProcess? {
        let requiredSelectors: [AudioObjectPropertySelector] = [
            kAudioProcessPropertyPID,
            kAudioProcessPropertyBundleID,
            kAudioProcessPropertyIsRunningInput,
            kAudioProcessPropertyIsRunningOutput
        ]
        guard requiredSelectors.allSatisfy({
            hasProperty(objectID: objectID, address: propertyAddress($0))
        }) else {
            return nil
        }

        guard let processID: pid_t = readScalar(
            objectID: objectID,
            address: propertyAddress(kAudioProcessPropertyPID)
        ),
        let bundleIdentifier = readBundleIdentifier(objectID: objectID),
        let input: UInt32 = readScalar(
            objectID: objectID,
            address: propertyAddress(kAudioProcessPropertyIsRunningInput)
        ),
        let output: UInt32 = readScalar(
            objectID: objectID,
            address: propertyAddress(kAudioProcessPropertyIsRunningOutput)
        ) else {
            return nil
        }

        return MeetingAudioProcess(
            audioObjectID: objectID,
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            isRunningInput: input != 0,
            isRunningOutput: output != 0
        )
    }

    private func readBundleIdentifier(objectID: AudioObjectID) -> String? {
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
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
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
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

    nonisolated private static func canonicalBundleIdentifier(
        for bundleIdentifier: String
    ) -> String? {
        if NativeMeetingAudioProcessRegistry.provider(for: bundleIdentifier) != nil {
            return bundleIdentifier
        }
        return BrowserAudioProcessAttribution.canonicalBrowserBundleIdentifier(
            for: bundleIdentifier
        )
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
