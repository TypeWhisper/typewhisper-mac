import CoreMediaIO
import Foundation
import os

protocol MeetingCameraActivityClient: Sendable {
    func start(changeHandler: @escaping @Sendable () -> Void) -> Bool
    func snapshot(at date: Date) -> MeetingCameraActivitySnapshot
    func stop()
}

private final class CoreMediaIOChangeCallbackBridge: @unchecked Sendable {
    private let handler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    func setHandler(_ newHandler: (@Sendable () -> Void)?) {
        handler.withLock { $0 = newHandler }
    }

    func notify() {
        let callback = handler.withLock { $0 }
        callback?()
    }
}

private final class CoreMediaIOListenerRegistration: @unchecked Sendable {
    let objectID: CMIOObjectID
    let address: CMIOObjectPropertyAddress
    let queue: DispatchQueue
    let block: CMIOObjectPropertyListenerBlock

    init(
        objectID: CMIOObjectID,
        address: CMIOObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping CMIOObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }
}

private struct CoreMediaIOCameraClientState {
    var systemRegistration: CoreMediaIOListenerRegistration?
    var deviceRegistrations: [CMIOObjectID: CoreMediaIOListenerRegistration] = [:]
    var started = false
}

final class CoreMediaIOCameraActivityClient: MeetingCameraActivityClient, @unchecked Sendable {
    private let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
    private let callbackQueue = DispatchQueue(
        label: "com.typewhisper.calendar-meeting-camera",
        qos: .utility
    )
    private let callbackBridge = CoreMediaIOChangeCallbackBridge()
    private let state = OSAllocatedUnfairLock(initialState: CoreMediaIOCameraClientState())

    func start(changeHandler: @escaping @Sendable () -> Void) -> Bool {
        stop()
        callbackBridge.setHandler(changeHandler)

        let devicesAddress = cameraPropertyAddress(
            CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        )
        guard hasProperty(objectID: systemObjectID, address: devicesAddress),
              let registration = addListener(
                  objectID: systemObjectID,
                  address: devicesAddress
              ) else {
            callbackBridge.setHandler(nil)
            return false
        }
        state.withLock {
            $0.systemRegistration = registration
            $0.started = true
        }
        return true
    }

    func snapshot(at date: Date) -> MeetingCameraActivitySnapshot {
        guard state.withLock({ $0.started }) else {
            return .unsupported(at: date)
        }
        guard let deviceIDs = readDeviceIDs() else {
            return .failed(at: date)
        }

        let observableDeviceIDs = Set(deviceIDs.filter { deviceID in
            hasProperty(
                objectID: deviceID,
                address: cameraPropertyAddress(
                    CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
                )
            )
        })
        guard reconcileDeviceListeners(deviceIDs: observableDeviceIDs) else {
            return .failed(at: date)
        }

        var isAnyCameraRunning = false
        for deviceID in observableDeviceIDs {
            guard let isRunning = readIsRunningSomewhere(deviceID: deviceID) else {
                return .failed(at: date)
            }
            if isRunning {
                isAnyCameraRunning = true
                break
            }
        }
        return MeetingCameraActivitySnapshot(
            capturedAt: date,
            availability: .available,
            isAnyCameraRunning: isAnyCameraRunning
        )
    }

    func stop() {
        let registrations = state.withLock { current -> [CoreMediaIOListenerRegistration] in
            var all = Array(current.deviceRegistrations.values)
            if let systemRegistration = current.systemRegistration {
                all.append(systemRegistration)
            }
            current = CoreMediaIOCameraClientState()
            return all
        }
        callbackBridge.setHandler(nil)
        registrations.forEach(removeListener)
    }

    private func readDeviceIDs() -> [CMIOObjectID]? {
        var address = cameraPropertyAddress(
            CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        )
        guard CMIOObjectHasProperty(systemObjectID, &address) else { return nil }
        var byteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            systemObjectID,
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else {
            return nil
        }
        let count = Int(byteCount) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }
        var values = Array(repeating: CMIOObjectID(0), count: count)
        var bytesUsed: UInt32 = 0
        let status = values.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(
                systemObjectID,
                &address,
                0,
                nil,
                byteCount,
                &bytesUsed,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        let returnedCount = min(
            values.count,
            Int(bytesUsed) / MemoryLayout<CMIOObjectID>.size
        )
        return Array(values.prefix(returnedCount))
    }

    private func readIsRunningSomewhere(deviceID: CMIOObjectID) -> Bool? {
        var address = cameraPropertyAddress(
            CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        )
        guard CMIOObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var bytesUsed: UInt32 = 0
        let byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            byteCount,
            &bytesUsed,
            &value
        ) == noErr,
        bytesUsed == byteCount else {
            return nil
        }
        return value != 0
    }

    private func reconcileDeviceListeners(deviceIDs: Set<CMIOObjectID>) -> Bool {
        let stale = state.withLock { Set($0.deviceRegistrations.keys).subtracting(deviceIDs) }
        for deviceID in stale {
            let registration = state.withLock {
                $0.deviceRegistrations.removeValue(forKey: deviceID)
            }
            if let registration {
                removeListener(registration)
            }
        }

        let known = state.withLock { Set($0.deviceRegistrations.keys) }
        for deviceID in deviceIDs.subtracting(known) {
            let address = cameraPropertyAddress(
                CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
            )
            guard let registration = addListener(objectID: deviceID, address: address) else {
                return false
            }
            state.withLock { $0.deviceRegistrations[deviceID] = registration }
        }
        return true
    }

    private func addListener(
        objectID: CMIOObjectID,
        address initialAddress: CMIOObjectPropertyAddress
    ) -> CoreMediaIOListenerRegistration? {
        var address = initialAddress
        guard CMIOObjectHasProperty(objectID, &address) else { return nil }
        let block = makeMeetingCameraPropertyListenerBlock(callbackBridge)
        guard CMIOObjectAddPropertyListenerBlock(
            objectID,
            &address,
            callbackQueue,
            block
        ) == noErr else {
            return nil
        }
        return CoreMediaIOListenerRegistration(
            objectID: objectID,
            address: initialAddress,
            queue: callbackQueue,
            block: block
        )
    }

    private func removeListener(_ registration: CoreMediaIOListenerRegistration) {
        var address = registration.address
        _ = CMIOObjectRemovePropertyListenerBlock(
            registration.objectID,
            &address,
            registration.queue,
            registration.block
        )
    }

    private func hasProperty(
        objectID: CMIOObjectID,
        address initialAddress: CMIOObjectPropertyAddress
    ) -> Bool {
        var address = initialAddress
        return CMIOObjectHasProperty(objectID, &address)
    }
}

private func cameraPropertyAddress(
    _ selector: CMIOObjectPropertySelector
) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: selector,
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
}

private func makeMeetingCameraPropertyListenerBlock(
    _ bridge: CoreMediaIOChangeCallbackBridge
) -> CMIOObjectPropertyListenerBlock {
    { _, _ in bridge.notify() }
}

private func makeMeetingCameraCollectorChangeHandler(
    _ collector: MeetingCameraActivityCollector
) -> @Sendable () -> Void {
    { [weak collector] in
        guard let collector else { return }
        Task {
            await collector.cameraPropertiesDidChange()
        }
    }
}

actor MeetingCameraActivityCollector: MeetingCameraActivityCollecting {
    private let client: any MeetingCameraActivityClient
    private var continuation: AsyncStream<MeetingCameraActivitySnapshot>.Continuation?
    private var lastPublishedSnapshot: MeetingCameraActivitySnapshot?
    private var isCollecting = false

    init() {
        client = CoreMediaIOCameraActivityClient()
    }

    init(client: any MeetingCameraActivityClient) {
        self.client = client
    }

    deinit {
        client.stop()
    }

    func startCollecting() -> AsyncStream<MeetingCameraActivitySnapshot> {
        stopCollecting()
        let pair = AsyncStream<MeetingCameraActivitySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = pair.continuation

        let handler = makeMeetingCameraCollectorChangeHandler(self)
        guard client.start(changeHandler: handler) else {
            pair.continuation.yield(.unsupported())
            pair.continuation.finish()
            continuation = nil
            return pair.stream
        }
        isCollecting = true
        publishCurrentSnapshot(force: true)
        return pair.stream
    }

    func stopCollecting() {
        guard isCollecting || continuation != nil else { return }
        isCollecting = false
        client.stop()
        continuation?.finish()
        continuation = nil
        lastPublishedSnapshot = nil
    }

    fileprivate func cameraPropertiesDidChange() {
        guard isCollecting else { return }
        publishCurrentSnapshot(force: true)
    }

    private func publishCurrentSnapshot(force: Bool = false) {
        guard isCollecting else { return }
        let snapshot = client.snapshot(at: Date())
        if !force,
           let lastPublishedSnapshot,
           lastPublishedSnapshot.availability == snapshot.availability,
           lastPublishedSnapshot.isAnyCameraRunning == snapshot.isAnyCameraRunning {
            return
        }
        lastPublishedSnapshot = snapshot
        continuation?.yield(snapshot)
    }
}
