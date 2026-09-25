import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "EventBus")

@MainActor
final class EventBus: EventBusProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var shared: EventBus!

    private struct Subscription: Sendable {
        let id: UUID
        let handler: @Sendable (TypeWhisperEvent) async -> Void
    }

    private var subscriptions: [Subscription] = []

    @discardableResult
    nonisolated func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        let id = UUID()
        let subscription = Subscription(id: id, handler: handler)
        DispatchQueue.main.async {
            self.subscriptions.append(subscription)
        }
        return id
    }

    nonisolated func unsubscribe(id: UUID) {
        DispatchQueue.main.async {
            self.subscriptions.removeAll { $0.id == id }
        }
    }

#if DEBUG
    /// Called synchronously for each emitted event, so tests can check the emission order.
    /// Subscribers run in detached tasks and may observe events in a different order.
    var emissionObserverForTesting: ((TypeWhisperEvent) -> Void)?
#endif

    func emit(_ event: TypeWhisperEvent) {
#if DEBUG
        emissionObserverForTesting?(event)
#endif
        let handlers = subscriptions.map { $0.handler }
        for handler in handlers {
            Task.detached {
                await handler(event)
            }
        }
        logger.debug("Emitted event to \(handlers.count) subscriber(s)")
    }
}
