import Foundation
import Combine

@MainActor
final class APIServerViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: APIServerViewModel?
    static var shared: APIServerViewModel {
        guard let instance = _shared else {
            fatalError("APIServerViewModel not initialized")
        }
        return instance
    }

    @Published var isRunning = false
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "apiServerEnabled") }
    }
    @Published var port: UInt16 {
        didSet { UserDefaults.standard.set(Int(port), forKey: "apiServerPort") }
    }
    @Published var errorMessage: String?

    private let httpServer: HTTPServer

    init(httpServer: HTTPServer) {
        self.httpServer = httpServer
        self.isEnabled = UserDefaults.standard.bool(forKey: "apiServerEnabled")
        let savedPort = UserDefaults.standard.integer(forKey: "apiServerPort")
        self.port = savedPort > 0 ? UInt16(savedPort) : 8978

        httpServer.onStateChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.isRunning = running
                if !running {
                    self?.errorMessage = "Server stopped unexpectedly"
                }
            }
        }
    }

    func startServer() {
        errorMessage = nil
        do {
            try httpServer.start(port: port)
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stopServer() {
        httpServer.stop()
        isRunning = false
        errorMessage = nil
    }

    func restartIfNeeded() {
        if isEnabled {
            stopServer()
            startServer()
        }
    }
}
