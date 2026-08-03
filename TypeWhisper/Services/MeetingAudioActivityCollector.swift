import CoreAudio
import Foundation
import os

protocol MeetingAudioProcessClient: Sendable {
    func start(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool
    func restart(changeHandler: @escaping @Sendable (Bool) -> Void) -> Bool
    func snapshot(at date: Date) -> MeetingActivitySnapshot
    func stop()
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

private final class CoreAudioMeetingProcessClient: MeetingAudioProcessClient, @unchecked Sendable {
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

        let addresses = [
            propertyAddress(kAudioHardwarePropertyProcessObjectList),
            propertyAddress(kAudioHardwarePropertyServiceRestarted)
        ]
        guard addresses.allSatisfy({ hasProperty(objectID: systemObjectID, address: $0) }) else {
            callbackBridge.setHandler(nil)
            return false
        }

        let registrations = addresses.compactMap { address in
            addListener(objectID: systemObjectID, address: address)
        }
        guard registrations.count == addresses.count else {
            registrations.forEach(removeListener)
            callbackBridge.setHandler(nil)
            return false
        }
        state.withLock {
            $0.systemRegistrations = registrations
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
            guard let process = readProcess(objectID: objectID) else { continue }
            guard process.processID != ownProcessID,
                  process.bundleIdentifier != ownBundleIdentifier else {
                continue
            }
            guard Self.isRelevantProcess(process.bundleIdentifier) else { continue }
            relevantObjectIDs.insert(objectID)
            processes.append(process)
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

    nonisolated private static func isRelevantProcess(_ bundleIdentifier: String) -> Bool {
        switch bundleIdentifier {
        case "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime":
            true
        default:
            SupportedMeetingBrowser.supportsAutomaticURLResolution(bundleIdentifier)
        }
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
    private var continuation: AsyncStream<MeetingActivitySnapshot>.Continuation?
    private var isCollecting = false

    init() {
        client = CoreAudioMeetingProcessClient()
    }

    init(client: any MeetingAudioProcessClient) {
        self.client = client
    }

    deinit {
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
        pair.continuation.yield(client.snapshot(at: Date()))
        return pair.stream
    }

    func stopCollecting() {
        guard isCollecting || continuation != nil else { return }
        isCollecting = false
        client.stop()
        continuation?.finish()
        continuation = nil
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
        continuation?.yield(client.snapshot(at: Date()))
    }
}
