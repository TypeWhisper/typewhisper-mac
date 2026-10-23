import Combine
import Network

@MainActor
final class SpeechNetworkStatus: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "dictum.speech.network"))
    }

    deinit { monitor.cancel() }
}
